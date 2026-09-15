# Deterministic software-system fixture: actual source imports and Git history,
# no real provider settings and no provider calls.
{:ok, _} = Application.ensure_all_started(:beam_agent)
root = Path.join(System.tmp_dir!(), "loom-atlas-#{System.unique_integer([:positive])}")
workspace = Path.join(root, "northstar-commerce")
File.mkdir_p!(workspace)
Application.put_env(:beam_agent, :discovery_dir, Path.join(root, "live"))
System.at_exit(fn _ -> File.rm_rf(root) end)

files = %{
  "src/ui/checkout.tsx" =>
    "import { order } from '../checkout/order';\nimport { login } from '../auth/login';\nexport const checkout = order;",
  "src/ui/account.tsx" => "import { login } from '../auth/login';\nexport const account = login;",
  "src/api/orders.ts" =>
    "import { order } from '../checkout/order';\napp.get('/api/orders', ordersHandler);\napp.post('/api/orders', createOrder);\nexport const orders = order;",
  "src/api/webhooks.ts" =>
    "import { payment } from '../payments/gateway';\nrouter.post('/api/webhooks/payment', paymentWebhook);\nexport const webhook = payment;",
  "src/auth/login.ts" =>
    "import { users } from '../data/users';\nimport { permissions } from '../domain/permissions';\nexport const login = users;",
  "src/auth/session.ts" =>
    "import { cache } from '../storage/cache';\nexport const session = cache;",
  "src/checkout/order.ts" =>
    "import { payment } from '../payments/gateway';\nimport { inventory } from '../domain/inventory';\nimport { orders } from '../data/orders';\nexport const order = orders;",
  "src/payments/gateway.ts" =>
    "import Stripe from 'stripe';\nimport { ledger } from '../data/ledger';\nexport const payment = ledger;",
  "src/notifications/email.ts" =>
    "import { users } from '../data/users';\nexport const email = users;",
  "src/domain/inventory.ts" =>
    "import { stock } from '../data/stock';\nexport const inventory = stock;",
  "src/domain/permissions.ts" => "export const permissions = ['read', 'write'];",
  "src/data/users.ts" => "import pg from 'pg';\nexport const users = [];",
  "src/data/orders.ts" => "import pg from 'pg';\nexport const orders = [];",
  "src/data/stock.ts" => "export const stock = [];",
  "src/data/ledger.ts" => "export const ledger = [];",
  "src/storage/cache.ts" => "import Redis from 'ioredis';\nexport const cache = new Map();",
  "src/checkout/order.test.ts" => "import { order } from './order';",
  "src/domain/inventory.test.ts" => "import { inventory } from './inventory';",
  "src/auth/login.test.ts" => "import { login } from './login';",
  "infra/production/main.tf" => "# Production infrastructure fixture",
  "infra/staging/main.tf" => "# Staging infrastructure fixture",
  "scripts/deploy/release.sh" => "# Release fixture",
  "docs/architecture/overview.md" =>
    "# Northstar Commerce\nCheckout, identity and payment boundaries.",
  "docs/runbooks/payments.md" =>
    "# Payment recovery\nReconcile the ledger before replaying events.",
  ".github/workflows/ci.yml" =>
    "name: Verify and build\non: [push, pull_request]\njobs:\n  tests:\n    runs-on: ubuntu-latest\n",
  "package.json" =>
    ~s({"name":"northstar-commerce","dependencies":{"stripe":"^17","pg":"^8","ioredis":"^5"}})
}

for {path, content} <- files do
  full = Path.join(workspace, path)
  File.mkdir_p!(Path.dirname(full))
  File.write!(full, content)
end

System.cmd("git", ["init", "-q"], cd: workspace)
System.cmd("git", ["add", "."], cd: workspace)

commit = fn message, date, name ->
  System.cmd(
    "git",
    [
      "-c",
      "user.name=#{name}",
      "-c",
      "user.email=fixture@example.invalid",
      "-c",
      "core.hooksPath=/dev/null",
      "commit",
      "--no-gpg-sign",
      "-qm",
      message
    ],
    cd: workspace,
    env: [{"GIT_AUTHOR_DATE", date}, {"GIT_COMMITTER_DATE", date}]
  )
end

commit.("Establish commerce boundaries", "2026-03-01T12:00:00Z", "Alex")

for n <- 1..12 do
  path = if rem(n, 3) == 0, do: "src/auth/login.ts", else: "src/checkout/order.ts"
  File.write!(Path.join(workspace, path), "\n// Iteration #{n}", [:append])
  System.cmd("git", ["add", path], cd: workspace)

  commit.(
    if(rem(n, 3) == 0, do: "Tighten identity checks", else: "Refine order lifecycle"),
    "2026-#{String.pad_leading(to_string(3 + div(n, 3)), 2, "0")}-#{String.pad_leading(to_string(n + 1), 2, "0")}T12:00:00Z",
    if(rem(n, 3) == 0, do: "Sam", else: "Alex")
  )
end

{:ok, id} =
  BeamAgent.start_session(
    workspace_root: workspace,
    data_dir: Path.join(root, "runtime"),
    provider: :echo,
    strategy: BeamAgent.Strategies.ToolLoop,
    repository_scan_interval_ms: 60_000
  )

token = "local-browser-fixture-token-only"
{:ok, server} = BeamAgent.start_web_control_plane(id, token: token, conversation: true)
{:ok, url} = BeamAgent.ControlPlane.HTTPServer.url(server)
Application.put_env(:beam_agent_web, :runtime_url, "http://127.0.0.1:#{URI.parse(url).port}")
Application.put_env(:beam_agent_web, :runtime_token, token)
config = Application.fetch_env!(:beam_agent_web, BeamAgentWeb.Endpoint)

Application.put_env(
  :beam_agent_web,
  BeamAgentWeb.Endpoint,
  Keyword.merge(config, server: true, http: [ip: {127, 0, 0, 1}, port: 4175])
)

{:ok, _} = Application.ensure_all_started(:beam_agent_web)
Process.sleep(:infinity)
