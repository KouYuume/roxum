import ../core/domain/user/UserRepository
import ../core/query_services/users/SearchUsersQueryService
import ../infrastructure/repositories/UserRepositoryImpl
import ../infrastructure/query_services/users/UserSearchImpl
import ../infrastructure/UserId

AppState := {
	save_user! : UserRepository.Save,
	find_user! : UserRepository.Find,
	search_users! : SearchUsersQueryService.Search,
	next_user_id! : ({} => Str),
}.{
	new = |db| AppState.{
		save_user!: |user| UserRepositoryImpl.save!(db, user),
		find_user!: |id| UserRepositoryImpl.find!(db, id),
		search_users!: |query| UserSearchImpl.search!(db, query),
		next_user_id!: UserId.generate!,
	}
}
