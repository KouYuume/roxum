app [program] {
	pf: platform "../../../platform/main.roc",
	pg: "../../../integrations/roxum-postgres/package/main.roc",
	hc: "../../../integrations/roxum-http-client/package/main.roc",
	http: "https://github.com/roc-lang/http/releases/download/2.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
}

## Composition root. There is no presentation/ or infrastructure/ wrapper:
## their concrete folders sit beside the core's application/ and domain/.
import "config/base.toml" as base_text : Str
import api/TaxRateApi
import controllers/ProductController
import database/ProductTable
import events/ExternalEventBus
import middleware/RequestLog
import queryServices/ProductQueryServiceImpl
import repositories/ProductRepositoryImpl
import pf.Config
import pf.Handler
import pf.MethodRouter
import pf.Router
import pf.Secret
import pf.IpAddr
import pf.Server
import hc.HttpClient
import pg.Postgres

Model := {
	repository : ProductRepositoryImpl,
	query_service : ProductQueryServiceImpl,
	tax_api : TaxRateApi,
	event_bus : ExternalEventBus,
}

program = { init!, routes: Router.build(routes, {}) }

## The shape of config/base.toml and config/local.toml. A key the type does
## not have is an error; `threads` and `metrics_port` may be left out of both
## files. With `metrics_port`, the admin port (`/metrics`, `/ready`, `/live`)
## listens on 127.0.0.1 there.
Settings : {
	listen : { port : U16, threads : Try(U16, [Missing]), metrics_port : Try(U16, [Missing]) },
	tax : { url : Str, token_file : Str },
	database : { host : Str, port : U16, user : Str, name : Str, password_file : Str },
}

## Decoded while compiling, so a base that does not fit `Settings` stops the
## build instead of the first deployment.
base_settings : Settings
base_settings = Config.check_base(base_text)

init! : {} => Try({ model : Model, listen : Server.ListenOptions }, [StartupErr(Str)])
init! = |{}| {
	settings : Settings
	settings = Config.load!(base_text).map_err(|ConfigErr(message)| StartupErr(message))?
	threads = match settings.listen.threads {
		Ok(count) => Server.Threads.Fixed(count)
		Err(Missing) => Server.Threads.Auto
	}
	metrics = match settings.listen.metrics_port {
		Ok(port) => Server.Metrics.Listen(Server.Endpoint.Tcp({ address: IpAddr.V4((127, 0, 0, 1)), port }))
		Err(Missing) => Server.Metrics.Off
	}
	# The password comes from a file the deployment mounts; the host keeps it.
	password = Secret.from_file!(settings.database.password_file).map_err(|_| StartupErr("cannot read the database password file"))?
	db = Postgres.pool!(
		Postgres.Config.{
			host: settings.database.host,
			port: settings.database.port,
			user: settings.database.user,
			database: settings.database.name,
			password: Postgres.Password.Secret(password),
		},
	).map_err(|_| StartupErr("invalid database settings"))?
	ProductTable.migrate!(db).map_err(|MigrationFailed| StartupErr("database migration failed"))?
	# One HTTP client for every outbound call; the tax token is a file too.
	http_client = HttpClient.client!(HttpClient.Config.{}).map_err(|_| StartupErr("cannot load the CA certificates"))?
	tax_token = Secret.from_file!(settings.tax.token_file).map_err(|_| StartupErr("cannot read the tax token file"))?
	Ok({
		model: {
			repository: ProductRepositoryImpl.new(db),
			query_service: ProductQueryServiceImpl.new(db),
			tax_api: TaxRateApi.new(http_client, settings.tax.url, tax_token),
			event_bus: ExternalEventBus.sample,
		},
		listen: {
			endpoint: Server.Endpoint.Tcp({ address: IpAddr.V4((127, 0, 0, 1)), port: settings.listen.port }),
			timeouts: Server.Timeouts.defaults,
			limits: Server.Limits.defaults,
			threads,
			metrics,
		},
	})
}

routes : Router(Model, [], {})
routes =
	Router.new
		.route("/products", MethodRouter.post(Handler.effectful(ProductController.create!)))
		.route("/products/{sku}", MethodRouter.get(Handler.effectful(ProductController.show!)))
		.route("/products/{sku}", MethodRouter.put(Handler.effectful(ProductController.update!)))
		.route("/products/{sku}", MethodRouter.delete(Handler.effectful(ProductController.delete!)))
		.route("/products/{sku}/quote/{quantity}", MethodRouter.get(Handler.effectful(ProductController.quote!)))
		.layer(RequestLog.layer)
