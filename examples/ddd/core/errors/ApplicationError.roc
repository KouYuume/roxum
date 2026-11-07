import DomainError
import InfrastructureError

ApplicationError := [Domain(DomainError), Infrastructure(InfrastructureError), EntityNotFound(Str)].{
	from_domain = |error| ApplicationError.(Domain(error))
	from_infrastructure = |error| ApplicationError.(Infrastructure(error))
}
