app [program] { pf: platform "../../../platform/main.roc", pg: "../package/main.roc" }

import pf.Config
import pf.Handler
import pf.MethodRouter
import pf.Reply
import pf.Router
import pf.Secret
import pf.Server
import pg.Postgres

Model := { db : Postgres.Pool }

program = { init!, routes: Router.build(routes, {}) }

init! = |{}| {
	settings : { port : U16, password : Bool }
	settings = Config.load!("port = 1\npassword = false").map_err(|_| StartupErr("config"))?
	password = if settings.password {
		loaded = Secret.from_env!("ROXUM_TEST_PASSWORD").map_err(|_| StartupErr("secret"))?
		Postgres.Password.Secret(loaded)
	} else {
		Postgres.Password.None
	}
	db = Postgres.pool!(Postgres.Config.{ host: "127.0.0.1", port: settings.port, user: "app", database: "app", password, maximum_connections: 1, statement_timeout_milliseconds: 100 }).map_err(|_| StartupErr("pool"))?
	Ok({
		model: { db },
		listen: {
			address: Server.Ipv4Address.(127, 0, 0, 1),
			port: 0,
			timeouts: Server.Timeouts.defaults,
			limits: Server.Limits.defaults,
			threads: Server.Threads.Fixed(1),
		},
	})
}

routes : Router(Model, [], {})
routes = Router.new
	.route(
		"/",
		MethodRouter.get(
			Handler.effectful(
				|model, _context| {
					result = Postgres.execute!(model.db, "SELECT 1", [])
					text = match result {
						Ok(_) => "ok"
						Err(PostgresLoginFailed(_)) => "login-failed"
						Err(PostgresTimedOut) => "timed-out"
						Err(_) => "other-error"
					}
					Ok(Reply.text(text))
				},
			),
		),
	)
