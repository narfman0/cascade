extends Node
## ContractManager — contract pool, acceptance, and completion callbacks.
##
## Responsibility (per architecture.md): owns the pool of available contracts,
## tracks the active contract, and routes completion/failure back to GameState.
## Populated in M3+. Empty registered autoload for now.
