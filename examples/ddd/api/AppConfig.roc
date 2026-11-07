import "config/base.toml" as base_text : Str
import pf.Config

AppConfig := [].{
	Settings : { database : { host : Str, port : U16, user : Str, name : Str, password_file : Str } }
	load! : {} => Try(AppConfig.Settings, [StartupErr(Str)])
	load! = |{}| Config.load!(base_text).map_err(|ConfigErr(message)| StartupErr(message))
}
