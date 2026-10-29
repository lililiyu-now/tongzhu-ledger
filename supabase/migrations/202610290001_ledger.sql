-- Apply once to a new Supabase project. All writes go through ledger_command.
create table public.spaces (id uuid primary key default gen_random_uuid(), name text not null check(length(name) between 1 and 60), created_at timestamptz not null default now());
create table public.members (id uuid primary key default gen_random_uuid(), space_id uuid not null references public.spaces, user_id uuid not null references auth.users, name text not null check(length(name) between 1 and 40), role text not null check(role in ('admin','member')), active boolean not null default true, joined_at timestamptz not null default now(), unique(space_id,user_id));
create unique index one_active_space on public.members(user_id) where active;
create table public.invites (id uuid primary key default gen_random_uuid(), space_id uuid not null references public.spaces, token_hash text unique not null check(length(token_hash)=64), expires_at timestamptz not null default now()+interval '7 days', revoked boolean not null default false);
create table public.bills (id uuid primary key default gen_random_uuid(), space_id uuid not null references public.spaces, payer_id uuid not null references public.members, title text not null check(length(title) between 1 and 100), spent_on date not null, total_cents bigint not null check(total_cents between 1 and 1000000000), split_method text not null check(split_method in ('equal','custom')), locked boolean not null default false, voided boolean not null default false, version integer not null default 1, created_at timestamptz not null default now());
create table public.shares (id uuid primary key default gen_random_uuid(), bill_id uuid not null references public.bills, member_id uuid not null references public.members, amount_cents bigint not null check(amount_cents>=0), status text not null check(status in ('pending','marked','confirmed','self')), unique(bill_id,member_id));
create table public.events (id uuid primary key default gen_random_uuid(), space_id uuid not null references public.spaces, bill_id uuid references public.bills, actor_id uuid not null references public.members, action text not null, details jsonb not null default '{}', created_at timestamptz not null default now());
create table public.command_receipts (user_id uuid not null references auth.users, request_id uuid not null, payload jsonb not null, result jsonb not null, primary key(user_id,request_id));
create index bills_space on public.bills(space_id,created_at desc);
create index shares_member on public.shares(member_id);
create index events_space on public.events(space_id,created_at);
create function public.my_space() returns uuid language sql stable security definer set search_path='' as $$ select space_id from public.members where user_id=auth.uid() and active $$;
revoke all on function public.my_space() from public;
grant execute on function public.my_space() to authenticated;
alter table public.spaces enable row level security;
alter table public.members enable row level security;
alter table public.invites enable row level security;
alter table public.bills enable row level security;
alter table public.shares enable row level security;
alter table public.events enable row level security;
alter table public.command_receipts enable row level security;
create policy space_read on public.spaces for select to authenticated using(id=public.my_space());
create policy member_read on public.members for select to authenticated using(space_id=public.my_space());
create policy bill_read on public.bills for select to authenticated using(space_id=public.my_space());
create policy share_read on public.shares for select to authenticated using(exists(select 1 from public.bills b where b.id=bill_id and b.space_id=public.my_space()));
create policy event_read on public.events for select to authenticated using(space_id=public.my_space());
revoke all on public.spaces,public.members,public.invites,public.bills,public.shares,public.events,public.command_receipts from anon,authenticated;
grant select on public.spaces,public.members,public.bills,public.shares,public.events to authenticated;

create function public.ledger_snapshot() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare sid uuid; me public.members;
begin
 if auth.uid() is null then raise exception '请先登录'; end if;
 select * into me from public.members where user_id=auth.uid() and active;
 if not found then return jsonb_build_object('space',null,'me',null,'members','[]'::jsonb,'bills','[]'::jsonb,'shares','[]'::jsonb,'events','[]'::jsonb); end if;
 sid:=me.space_id;
 return jsonb_build_object('space',(select to_jsonb(s) from public.spaces s where id=sid),'me',to_jsonb(me),
 'members',coalesce((select jsonb_agg(m order by m.joined_at,m.id) from public.members m where space_id=sid),'[]'::jsonb),
 'bills',coalesce((select jsonb_agg(b order by b.created_at desc,b.id) from public.bills b where space_id=sid),'[]'::jsonb),
 'shares',coalesce((select jsonb_agg(s) from public.shares s join public.bills b on b.id=s.bill_id where b.space_id=sid),'[]'::jsonb),
 'events',coalesce((select jsonb_agg(e order by e.created_at desc,e.id) from public.events e where space_id=sid),'[]'::jsonb));
end $$;

create function public.ledger_command(p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); req uuid; cmd text:=p->>'command'; me public.members; target public.members; b public.bills; sh public.shares; inv public.invites; old public.command_receipts; sid uuid; bid uuid; result jsonb:='{}'; entries jsonb; item jsonb; n integer; total bigint; amount bigint; amount_sum bigint:=0; idx integer:=0; participant uuid; reason text; detail jsonb; event_action text;
begin
 if uid is null then raise exception '请先登录'; end if;
 req:=(p->>'request_id')::uuid;
 if req is null then raise exception '缺少请求标识'; end if;
 -- Tiny-household workload: serialize commands to cover membership, invite and bill races.
 perform pg_advisory_xact_lock(72184021);
 select * into old from public.command_receipts where user_id=uid and request_id=req;
 if found then
  if old.payload<>p then raise exception '请求标识已被用于其他操作'; end if;
  return old.result;
 end if;
 select * into me from public.members where user_id=uid and active;
 if cmd in ('create_space','join_space') then
  if me.id is not null then raise exception '每个账号只能加入一个空间'; end if;
  if length(trim(coalesce(p->>'name',''))) not between 1 and 40 then raise exception '请输入 1–40 字的昵称'; end if;
  if cmd='create_space' then
   if length(trim(coalesce(p->>'space_name',''))) not between 1 and 60 then raise exception '请输入 1–60 字的空间名称'; end if;
   insert into public.spaces(name) values(trim(p->>'space_name')) returning id into sid;
   insert into public.members(space_id,user_id,name,role) values(sid,uid,trim(p->>'name'),'admin') returning * into me;
  else
   select * into inv from public.invites where token_hash=p->>'token_hash' and not revoked and expires_at>now();
   if not found then raise exception '邀请已失效或已撤销，请联系管理员'; end if;
   sid:=inv.space_id;
   if exists(select 1 from public.members where space_id=sid and user_id=uid) then
    update public.members set active=true,name=trim(p->>'name'),joined_at=now() where space_id=sid and user_id=uid returning * into me;
   else
    insert into public.members(space_id,user_id,name,role) values(sid,uid,trim(p->>'name'),'member') returning * into me;
   end if;
  end if;
  insert into public.events(space_id,actor_id,action) values(sid,me.id,cmd);
 elsif me.id is null then raise exception '请先加入合租空间';
 elsif cmd='create_invite' then
  if me.role<>'admin' then raise exception '仅管理员可邀请室友'; end if;
  update public.invites set revoked=true where space_id=me.space_id;
  insert into public.invites(space_id,token_hash) values(me.space_id,p->>'token_hash') returning * into inv;
  result:=jsonb_build_object('expires_at',inv.expires_at);
  insert into public.events(space_id,actor_id,action) values(me.space_id,me.id,cmd);
 elsif cmd='revoke_invite' then
  if me.role<>'admin' then raise exception '仅管理员可撤销邀请'; end if;
  update public.invites set revoked=true where space_id=me.space_id;
  insert into public.events(space_id,actor_id,action) values(me.space_id,me.id,cmd);
 elsif cmd in ('leave_space','deactivate_member') then
  select * into target from public.members where id=case when cmd='leave_space' then me.id else (p->>'member_id')::uuid end and space_id=me.space_id and active;
  if not found then raise exception '成员不存在或已停用'; end if;
  if cmd='deactivate_member' and me.role<>'admin' then raise exception '仅管理员可停用成员'; end if;
  if target.role='admin' then raise exception '第一版管理员需要保留在空间内'; end if;
  if exists(select 1 from public.bills debt_bill join public.shares s on s.bill_id=debt_bill.id where debt_bill.space_id=me.space_id and not debt_bill.voided and s.amount_cents>0 and s.status in ('pending','marked') and (debt_bill.payer_id=target.id or s.member_id=target.id)) then raise exception '该成员有未结清款项，暂不能退出或停用'; end if;
  update public.members set active=false where id=target.id;
  insert into public.events(space_id,actor_id,action,details) values(me.space_id,me.id,cmd,jsonb_build_object('member_id',target.id));
 elsif cmd in ('create_bill','edit_bill') then
  if cmd='edit_bill' then
   select * into b from public.bills where id=(p->>'bill_id')::uuid and space_id=me.space_id for update;
   if not found then raise exception '账单不存在或无权限'; end if;
   if b.payer_id<>me.id then raise exception '只有垫付人可修改'; end if;
   if b.locked or b.voided then raise exception '账单已锁定或作废，不能修改'; end if;
   if b.version<>(p->>'version')::integer or p->>'version' is null then raise exception '账单已更新，请刷新后重试'; end if;
  end if;
  if length(trim(coalesce(p->>'title',''))) not between 1 and 100 then raise exception '请输入 1–100 字的账单名称'; end if;
  if jsonb_typeof(p->'total_cents')<>'number' or (p->>'total_cents')!~'^[0-9]+$' then raise exception '金额必须为整数分'; end if;
  total:=(p->>'total_cents')::bigint;
  if total not between 1 and 1000000000 then raise exception '金额必须在 0.01 至 10000000 元之间'; end if;
  if p->>'spent_on' is null or (p->>'spent_on')::date>current_date then raise exception '请选择有效且不晚于今天的支出日期'; end if;
  if coalesce(p->>'split_method','') not in ('equal','custom') then raise exception '无效分摊方式'; end if;
  entries:=p->'participants';
  if jsonb_typeof(entries) is distinct from 'array' then raise exception '请选择参与成员'; end if;
  n:=jsonb_array_length(entries);
  if n<1 or n>100 then raise exception '参与人数必须为 1–100 人'; end if;
  if (select count(distinct x->>'member_id') from jsonb_array_elements(entries) x)<>n then raise exception '参与人不能重复'; end if;
  for item in select x from jsonb_array_elements(entries) x loop
   if not exists(select 1 from public.members where id=(item->>'member_id')::uuid and space_id=me.space_id and active) then raise exception '参与人不存在或已离开空间'; end if;
   if p->>'split_method'='custom' then
    if jsonb_typeof(item->'amount_cents') is distinct from 'number' or (item->>'amount_cents')!~'^[0-9]+$' then raise exception '每人金额必须为非负整数分'; end if;
    amount:=(item->>'amount_cents')::bigint;
    if amount>total then raise exception '个人分摊不能大于总额'; end if;
    amount_sum:=amount_sum+amount;
   end if;
  end loop;
  if p->>'split_method'='custom' and amount_sum<>total then raise exception '每人分摊金额之和必须等于总额'; end if;
  if cmd='create_bill' then
   insert into public.bills(space_id,payer_id,title,spent_on,total_cents,split_method) values(me.space_id,me.id,trim(p->>'title'),(p->>'spent_on')::date,total,p->>'split_method') returning id into bid;
  else
   bid:=b.id;
   update public.bills set title=trim(p->>'title'),spent_on=(p->>'spent_on')::date,total_cents=total,split_method=p->>'split_method',version=version+1 where id=bid;
   delete from public.shares where bill_id=bid;
  end if;
  for item in select x from jsonb_array_elements(entries) x join public.members m on m.id=(x->>'member_id')::uuid order by m.joined_at,m.id loop
   participant:=(item->>'member_id')::uuid;
   amount:=case when p->>'split_method'='custom' then (item->>'amount_cents')::bigint else total/n+case when idx<total%n then 1 else 0 end end;
   insert into public.shares(bill_id,member_id,amount_cents,status) values(bid,participant,amount,case when participant=me.id then 'self' when amount=0 then 'confirmed' else 'pending' end);
   idx:=idx+1;
  end loop;
  detail:=jsonb_build_object('title',trim(p->>'title'),'total_cents',total,'spent_on',p->>'spent_on','split_method',p->>'split_method','shares',(select jsonb_agg(to_jsonb(s)) from public.shares s where bill_id=bid));
  if cmd='edit_bill' then detail:=detail||jsonb_build_object('previous_bill',to_jsonb(b)); end if;
  insert into public.events(space_id,bill_id,actor_id,action,details) values(me.space_id,bid,me.id,cmd,detail);
  result:=jsonb_build_object('bill_id',bid);
 elsif cmd='void_bill' then
  select * into b from public.bills where id=(p->>'bill_id')::uuid and space_id=me.space_id for update;
  if not found then raise exception '账单不存在或无权限'; end if;
  if b.payer_id<>me.id or b.locked then raise exception '仅垫付人能作废从未付款的账单'; end if;
  if not b.voided then
   update public.bills set voided=true,version=version+1 where id=b.id;
   insert into public.events(space_id,bill_id,actor_id,action) values(me.space_id,b.id,me.id,cmd);
  end if;
 elsif cmd in ('mark_paid','withdraw_paid','confirm_received','reject_paid','undo_received') then
  select b0.* into b from public.bills b0 join public.shares s on s.bill_id=b0.id where s.id=(p->>'share_id')::uuid and b0.space_id=me.space_id for update of b0;
  if not found or b.voided then raise exception '账单不存在、已作废或无权限'; end if;
  select * into sh from public.shares where id=(p->>'share_id')::uuid for update;
  if sh.status='self' or sh.amount_cents=0 then raise exception '此份额无需转账'; end if;
  if cmd in ('mark_paid','withdraw_paid') and sh.member_id<>me.id then raise exception '只能操作自己的付款'; end if;
  if cmd in ('confirm_received','reject_paid','undo_received') and b.payer_id<>me.id then raise exception '只有垫付人能确认或退回收款'; end if;
  reason:=trim(coalesce(p->>'reason',''));
  if cmd in ('reject_paid','undo_received') and length(reason) not between 1 and 300 then raise exception '请填写 1–300 字的原因'; end if;
  if cmd='mark_paid' and sh.status<>'pending' then raise exception '付款状态已改变，请刷新'; end if;
  if cmd in ('withdraw_paid','confirm_received','reject_paid') and sh.status<>'marked' then raise exception '付款状态已改变，请刷新'; end if;
  if cmd='undo_received' and sh.status<>'confirmed' then raise exception '收款状态已改变，请刷新'; end if;
  update public.shares set status=case when cmd='mark_paid' then 'marked' when cmd='confirm_received' then 'confirmed' else 'pending' end where id=sh.id;
  update public.bills set locked=true,version=version+1 where id=b.id;
  insert into public.events(space_id,bill_id,actor_id,action,details) values(me.space_id,b.id,me.id,cmd,jsonb_build_object('member_id',sh.member_id,'amount_cents',sh.amount_cents,'reason',reason));
 else raise exception '不支持的操作';
 end if;
 insert into public.command_receipts(user_id,request_id,payload,result) values(uid,req,p,result);
 return result;
end $$;
revoke all on function public.ledger_snapshot(),public.ledger_command(jsonb) from public,anon;
grant execute on function public.ledger_snapshot(),public.ledger_command(jsonb) to authenticated;
