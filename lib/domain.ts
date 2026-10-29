export type Member = {id:string;space_id:string;user_id:string;name:string;role:'admin'|'member';active:boolean;joined_at:string};
export type Bill = {id:string;space_id:string;payer_id:string;title:string;spent_on:string;total_cents:number;split_method:'equal'|'custom';locked:boolean;voided:boolean;version:number;created_at:string};
export type Share = {id:string;bill_id:string;member_id:string;amount_cents:number;status:'pending'|'marked'|'confirmed'|'self'};
export type LedgerEvent = {id:string;bill_id:string|null;actor_id:string;action:string;details:Record<string,unknown>;created_at:string};
export type Snapshot = {space:{id:string;name:string}|null;me:Member|null;members:Member[];bills:Bill[];shares:Share[];events:LedgerEvent[]};
export function cents(value:string):number {if(!/^\d+(\.\d{1,2})?$/.test(value.trim()))throw Error('请输入最多两位小数的金额');const [a,b='']=value.trim().split('.');const n=Number(a)*100+Number(b.padEnd(2,'0'));if(!Number.isSafeInteger(n)||n>1000000000)throw Error('金额超出范围');return n;}
export const money=(n:number)=>new Intl.NumberFormat('zh-CN',{style:'currency',currency:'CNY'}).format(n/100);
export function splitEqual(total:number,members:Member[]){const ordered=[...members].sort((a,b)=>a.joined_at.localeCompare(b.joined_at)||a.id.localeCompare(b.id));return ordered.map((m,i)=>({member_id:m.id,amount_cents:Math.floor(total/ordered.length)+(i<total%ordered.length?1:0)}));}
export function settled(b:Bill,shares:Share[]){return !b.voided&&shares.filter(s=>s.bill_id===b.id).every(s=>s.status==='confirmed'||s.status==='self');}
export const actionLabels:Record<string,string>={create_space:'创建空间',join_space:'加入空间',create_invite:'生成邀请（旧邀请失效）',revoke_invite:'撤销邀请',leave_space:'退出空间',deactivate_member:'停用成员',create_bill:'创建账单',edit_bill:'修改账单',void_bill:'作废账单',mark_paid:'标记已付款',withdraw_paid:'撤回付款标记',confirm_received:'确认收到款项',reject_paid:'退回付款标记',undo_received:'撤销收款确认'};
