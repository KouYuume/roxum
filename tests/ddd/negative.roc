app [program] { pf: platform "../../platform/main.roc" }
import core/domain/user/User
import negative/UserWithEffect
import pf.Handler
import pf.MethodRouter
import pf.Reply
import pf.Router
import pf.IpAddr
import pf.Server

Model := {}

program = { init!, routes: Router.build(routes, {}) }

init! = |{}| Ok({ model: {}, listen: { address: IpAddr.V4((127, 0, 0, 1)), port: 0, timeouts: Server.Timeouts.defaults, limits: Server.Limits.defaults } })

routes : Router(Model, [], {})
routes = Router.new.route("/", MethodRouter.get(Handler.static(|{}| Reply.text(User.name(UserWithEffect.make("id"))))))
