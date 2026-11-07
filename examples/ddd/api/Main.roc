import AppConfig
import AppState
import ../infrastructure/database/Pool
import pf.Server

Main := [].{
	init! : {} => Try({ model : AppState, listen : Server.ListenOptions }, [StartupErr(Str)])
	init! = |{}| {
		settings : AppConfig.Settings
		settings = AppConfig.load!({})?
		db = Pool.connect!(settings.database)?
		Pool.migrate!(db).map_err(|_| StartupErr("database migration failed"))?
		Ok({
			model: AppState.new(db),
			listen: {
				address: Server.Ipv4Address.(127, 0, 0, 1),
				port: 0,
				timeouts: Server.Timeouts.defaults,
				limits: Server.Limits.defaults,
			},
		})
	}

}
