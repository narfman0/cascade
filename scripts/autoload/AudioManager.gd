extends Node
## AudioManager — ambient audio and positional SFX helpers.
##
## Responsibility (per architecture.md): centralized playback for ambient
## beds and one-shot positional SFX. No audio assets exist yet — `note_event`
## is the call site systems use now so that adding sound later is a matter of
## filling in this file, not hunting for the moments worth scoring.

## Named gameplay moment worth a sound. Silent until assets land.
func note_event(_event: StringName, _position: Variant = null) -> void:
	pass
