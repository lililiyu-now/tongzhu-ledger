# 同住 · 合租账本

Next.js + TypeScript + Supabase Auth/Postgres，面向一套合租房的共同账单管理。真实部署从空空间开始；旧 Sites 演示页及其 localStorage 数据不迁移。

## 本地立即体验

需要 Node.js 22+。已安装依赖的当前工作区可以直接运行：

```sh
./scripts/start-local.sh
```

打开 http://127.0.0.1:3000 。启动脚本在系统 Node 版本不足时会尝试 Codex 随附的 Node。其他机器首次使用请先在 Node 22+ 环境执行 `npm ci`。

也可以直接执行 `npm run dev:local`。本地模式用 PGlite（真正的 PostgreSQL WASM 引擎）运行**同一份 SQL 迁移、RLS 和事务函数**，数据持久化到 `.local/postgres/`。测试身份仅用于 localhost 开发模式，不发送验证码、不连接 Supabase，也不发起支付。浏览器标签页通过 sessionStorage 分别记住测试身份；账单存储在服务端数据库中。

第一次使用：

1. 选择林予，创建小屋；在“小屋与室友”中生成邀请。
2. 在另一个标签页打开邀请，选择周可并确认加入；第三个标签页选择许然加入。
3. 林予创建 100 元账单，三人均分；提交前应显示 33.34 / 33.33 / 33.33。
4. 周可标记付款；林予刷新后确认收款。许然尚未付款时，账单仍为未结清。
5. 可尝试退回、撤销误确认、自定义金额，以及未结清成员退出被阻止。

原开发机器的本地验收数据中有“梧桐小屋 · 本地验收”和一笔 100 元测试账单；这些记录不上传到 GitHub，新克隆的项目从空空间开始。自动化测试使用独立内存数据库，不污染这些本地记录。要重新开始，请先停止本地服务器，将 `.local` 目录改名后重启；旧目录可以恢复。

## 功能规则

- 每个账号只能有一个活跃空间；管理员邀请、撤销邀请和停用成员。管理员第一版不能退出，无管理员转让入口。
- 仅记录自己垫付的账单，参与人可以不包含垫付人；均分或自定义金额。金额为整数分，上限 1000 万元，支出日期不能晚于数据库当天日期。
- 均分余数按 `joined_at, id` 排序逐分分配。零金额份额无需转账；垫付人份额标记为自己承担。
- 待付款 → 已标记付款 → 已确认收款。确认前可撤回，垫付人可附原因退回或撤销误确认。
- 一旦发生过付款标记，账单永久锁定，即使撤回或退回也不能编辑/作废。未锁定账单由垫付人修改或作废；编辑使用版本校验。
- 完成状态从逐人份额计算，无整单一键结清。作废记录不计入待办，历史记录保留。
- 成员有未结清应付或应收款项时，不能退出或停用；已停用成员不再访问空间，但历史份额保留。重新获邀时复用其历史成员 ID。
- 每 15 秒及窗口重新聚焦时重新读取快照；也可手动刷新。第一版无推送或催款邮件。

## 连接真实 Supabase

1. 创建隔离的 Supabase 项目，在 SQL Editor 执行 `supabase/migrations/202610290001_ledger.sql`（只执行一次；后续修改追加新迁移）。
2. 复制 `.env.example` 为 `.env.local`，填写项目 URL 和 publishable/anon key。**不需要 service_role key。** 不要提交 `.env.local`。
3. 在 Authentication → Email Templates 的 Magic Link 模板中使用 `{{ .Token }}` 输出验证码，例如 `<h2>同住登录验证码</h2><p>{{ .Token }}</p>`；否则默认模板可能只发送登录链接。
4. 启用邮箱登录和新用户注册，关闭本应用不使用的身份提供方；按需设置验证码过期与发送频率，配置生产 SMTP、已验证发件域名及 SPF/DKIM。发送失败或验证码失效会在界面反馈，验证码错误不会清空输入。
5. 配置 Site URL 与实际 Vercel 域名；本地测试可用 http://localhost:3000。停止本地测试模式后，使用 `npm run dev` 进入真实邮箱登录模式。
6. 用两封你控制的邮箱实际验证收信、登录、邀请加入、付款和收款。未进行此项验证前，不视为可供真实室友使用的上线版本。

Supabase 官方文档：[邮箱验证码](https://supabase.com/docs/guides/auth/auth-email-passwordless)、[RLS](https://supabase.com/docs/guides/database/postgres/row-level-security)。

## 数据与 API

表：`spaces`、`members`、`invites`、`bills`、`shares`、`events`、`command_receipts`。

浏览器只使用 Supabase Auth 获取会话，账本接口是：

- `GET /api/ledger`：要求 Bearer 会话，返回当前空间、本人、成员、账单、份额与操作记录。
- `POST /api/ledger`：要求 Bearer 会话及 JSON；公共字段 `command`、UUID `request_id`。响应为操作结果或 `{error}`，不缓存。
- 命令：`create_space`、`join_space`、`create_invite`、`revoke_invite`、`leave_space`、`deactivate_member`、`create_bill`、`edit_bill`、`void_bill`、`mark_paid`、`withdraw_paid`、`confirm_received`、`reject_paid`、`undo_received`。对应字段见迁移与 UI 调用。

数据库 `ledger_command(jsonb)` 是唯一写入口，函数检查 `auth.uid()`、空间成员身份、角色、金额和状态。函数固定空 search_path；所有表启用 RLS，客户端无直接写权限，邀请和幂等回执不允许直接读取。随机邀请令牌由服务端产生，数据库只存 SHA-256 摘要，7 天有效；生成新邀请会撤销旧邀请。不要在日志中记录 Authorization 或完整邀请 URL。

同一用户、同一请求 ID、同一请求内容只执行一次。网络失败保留表单和请求 ID；刷新核对后重试。邀请生成若响应丢失，重试生成新令牌并撤销前一个，避免保存明文令牌。所有写入采用事务；小型合租场景使用事务级 advisory lock 串行化，覆盖成员退出、邀请与付款竞争。规模扩大后需改为稳定排序的按空间锁和分页快照。

本地测试头 `x-local-user` **只在** NODE_ENV=development、LOCAL_SANDBOX=1 且请求 hostname 为 localhost/127.0.0.1 时生效。启动器仅绑定 127.0.0.1。生产构建会移除测试入口，不应设置本地测试变量。

## 检查与验收

```sh
npm test
npm run typecheck
npm run build
```

`tests/database.test.ts` 在隔离 PGlite 中创建 Supabase auth.uid 的测试替身，并以 authenticated/anon 角色验证原始迁移。覆盖分币、权限、状态流转、永久锁定、幂等、邀请过期/撤销、成员退出、跨空间 RLS 与直接写入拒绝。它不模拟邮件送达，也不能代替真实 Supabase 的网络并发和跨设备验收。浏览器已实测三位测试身份邀请加入、100 元均分、付款标记、跨标签页刷新及部分收款不结清整单；真实邮件及手机视口验收尚未完成。

## Vercel 上线（尚未执行）

使用 Next.js 默认构建，将项目根目录设为本目录，Node 设置为 22 或 24。在 Vercel 中配置两项 Supabase 公共变量，不要设置 LOCAL_SANDBOX 或 NEXT_PUBLIC_LOCAL_SANDBOX。为 Preview 和 Production 分别使用隔离 Supabase 项目，以免预览影响真实账本。

执行迁移后先发布 Preview；完成真实邮箱、双会话一致性、手机视口和跨空间访问验证再发布 Production。上线初期关注登录失败、API 5xx 和数据库异常，日志只记录错误类别和 request_id，避免记录个人金额、验证码与令牌。托管平台回滚不回滚数据库；后续迁移只追加，不修改已应用迁移。

当前仅完成本地应用。Supabase、生产邮件、域名及 Vercel 账号尚未配置，因此没有新的云端生产网址。
