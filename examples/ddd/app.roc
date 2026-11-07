app [program] {
	pf: platform "../../platform/main.roc",
	pg: "../../integrations/roxum-postgres/package/main.roc",
}

import api/AppState
import api/Main
import api/Routes
import pf.Router

Model : AppState

program = { init!: Main.init!, routes: Router.build(Routes.routes, {}) }
