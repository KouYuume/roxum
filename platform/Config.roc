import toml.Toml
import toml.TomlValue
import File

## Settings from TOML files: a base compiled into the program, with the
## override file `config/local.toml` laid over it at startup.
##
## ```roc
## import "config/base.toml" as base_text : Str
##
## Settings : { listen : { port : U16 }, database : { host : Str, port : U16 } }
##
## init! = |{}| {
##     settings : Settings
##     settings = Config.load!(base_text).map_err(|ConfigErr(message)| StartupErr(message))?
##     ...
## }
## ```
##
## Tables merge key by key, so `config/local.toml` names only what differs
## for the environment; any other value it names, including an array,
## replaces the base value. The override file must exist, even if empty, so a
## deployment that forgot it does not start with the base settings.
##
## Keys the settings type does not have are errors, and errors name the key
## path but never the value. A key may be left out of both files when its
## field is `Try(T, [Missing])`.
Config := [].{
	## Where the override file is read from, relative to the working directory.
	local_path : Str
	local_path = "config/local.toml"

	## The base laid under `config/local.toml`, decoded into the settings type.
	## Call it from `init!`.
	load! = |base_text| {
		base = parse("config/base.toml", base_text)?
		local_text = match File.read_utf8!(Config.local_path, maximum_bytes) {
			Ok(text) => text
			Err(FileNotFound) => return Err(ConfigErr("${Config.local_path} not found; create it, even if empty"))
			Err(FilePermissionDenied) => return Err(ConfigErr("${Config.local_path} cannot be read: permission denied"))
			Err(FileTooLarge) => return Err(ConfigErr("${Config.local_path} is larger than 1 MiB"))
			Err(FileReadFailed) => return Err(ConfigErr("${Config.local_path} cannot be read"))
			Err(FileNotUtf8) => return Err(ConfigErr("${Config.local_path} is not UTF-8"))
		}
		local = parse(Config.local_path, local_text)?
		decode("config", Toml.merge(base, local))
	}

	## The base alone, decoded into the settings type; crashes when it is not
	## valid. Defined at the top level, the decoding runs while compiling, so a
	## broken base stops the build:
	##
	## ```roc
	## base_settings : Settings
	## base_settings = Config.check_base(base_text)
	## ```
	check_base = |base_text| {
		decoded = match parse("config/base.toml", base_text) {
			Ok(base) => decode("config/base.toml", base)
			Err(problem) => Err(problem)
		}
		match decoded {
			Ok(settings) => settings
			Err(ConfigErr(message)) => crash message
		}
	}
}

maximum_bytes : U64
maximum_bytes = 1_048_576

parse : Str, Str -> Try(TomlValue, [ConfigErr(Str)])
parse = |name, text|
	match Toml.parse(text) {
		Ok(value) => Ok(value)
		Err(TomlSyntax(message)) => Err(ConfigErr("${name}: ${message}"))
	}

decode = |name, value|
	match Toml.decode(value) {
		Ok(settings) => Ok(settings)
		Err(TomlDecode(message)) => Err(ConfigErr("${name}: ${message}"))
		Err(MissingRequiredField(field)) => Err(ConfigErr("${name}: missing key ${field}"))
	}
