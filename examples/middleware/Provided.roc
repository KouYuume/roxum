import User

## What the layers leave for the handlers: the user `Layers.authenticate`
## found. `Unset` means no layer set it, which is a mistake in the routes.
Provided := { user : Try(User, [Unset]) ?? Err(Unset) }
