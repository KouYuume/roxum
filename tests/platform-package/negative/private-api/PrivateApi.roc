import pf.HostLog

PrivateApi := [].{
	write! : Str => {}
	write! = |message| HostLog.write!(1, message)
}
