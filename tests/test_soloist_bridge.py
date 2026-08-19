"""Translation tests for soloist-bridge.

PLAYBACK_STATE below is a REAL capture from `soloist ctl trace` against the
paired, logged-in daemon on the hardware test device (tannoy,
192.168.1.12), captured 2026-08-19 while a track sat paused. It is used
verbatim (only reformatted for readability) rather than the documentation's
hand-written example, per the spike note: "where a real capture disagrees
with the brief's fixture, the capture wins."

The other event shapes below (track_changed, playback_changed,
position_sync, queue_changed, options_changed) were NOT captured live in
this session -- the paired device sat paused and idle throughout, and
producing them organically would have needed either waiting on someone
else's Spotify session or sending it play/queue/shuffle commands, which
this task treats as out of bounds without saying so up front (only the
already-running `get_state` on connect and read-only `ctl` queries were
sent to the live daemon). Their fixtures below reuse the exact entity-
envelope shapes confirmed by the real PLAYBACK_STATE capture and by the
2026-08-19 spike notes (docs/superpowers/notes/2026-08-19-soloist-spike.md),
which already exercised the full event set once against this same device.
"""
import importlib.util
import pathlib

spec = importlib.util.spec_from_loader("soloist_bridge", loader=None)
bridge = importlib.util.module_from_spec(spec)
exec(pathlib.Path(__file__).parent.parent.joinpath("scripts/soloist-bridge").read_text(),
     bridge.__dict__)


# Real capture, `soloist ctl trace` on tannoy, 2026-08-19. Device was paused
# and idle -- status, position.speed=0 reflect that faithfully.
PLAYBACK_STATE = {
    "type": "playback_state",
    "status": "paused",
    "item": {
        "uri": "spotify:track:0jVo3e34A15l6MNu1O3cfa",
        "entity_type": "track",
        "decorations": {
            "identity": {"name": "Red Right Hand - 2011 Remaster"},
            "visual_identity": {"cover": [
                {"url": "https://i.scdn.co/image/ab67616d0000485199249d4ab96f4760017c40ae",
                 "size": "small"},
                {"url": "https://i.scdn.co/image/ab67616d00001e0299249d4ab96f4760017c40ae",
                 "size": "default"},
                {"url": "https://i.scdn.co/image/ab67616d0000b27399249d4ab96f4760017c40ae",
                 "size": "large"},
                {"url": "https://i.scdn.co/image/ab67616d0000b27399249d4ab96f4760017c40ae",
                 "size": "xlarge"},
            ]},
            "parent": {"entity": {
                "uri": "spotify:album:3OlT3zr0bvzYYg2Dwn6Fkx",
                "entity_type": "album",
                "decorations": {"identity": {"name": "Let Love In (2011 Remaster)"}},
            }},
            "creators": [
                {"entity": {
                    "uri": "spotify:artist:4UXJsSlnKd7ltsrHebV79Q",
                    "entity_type": "artist",
                    "decorations": {"identity": {"name": "Nick Cave & The Bad Seeds"}},
                }},
            ],
            "playback": {"duration_ms": 370573, "content_ratings": []},
        },
    },
    # Real capture: a populated context. Note the spike also observed
    # context can be `{"uri": ""}` when nothing is playing from a context --
    # song_from_item() never reads "context" at all, so that shape does not
    # affect the code under test either way.
    "context": {
        "uri": "spotify:playlist:37i9dQZF1E8RiNOwdmj9jd",
        "entity_type": "playlist",
        "decorations": {"identity": {"name": "Red Right Hand - 2011 Remaster Radio"}},
    },
    "position": {"position_ms": 310404, "timestamp_ms": 1787156496351, "speed": 0},
    "volume": 100,
    "is_active": True,
    "options": {
        "shuffle": False, "repeat": "off", "playback_speed": 1,
        # Real capture: "modes" carries an undocumented key. translate() and
        # song_from_item() never read "modes" or "available_actions", so
        # neither affects the code under test -- included here only so the
        # fixture is an honest, unmodified copy of the wire payload.
        "modes": {"context_enhancement": "NONE"},
    },
    "available_actions": {
        "add_to_queue": {}, "play": {}, "seek": {}, "seek_backward": {"step_ms": 15000},
        "seek_forward": {"step_ms": 15000}, "set_repeat": {}, "shuffle": {}, "skip_next": {},
        # Real capture notably has NO "skip_prev" key here, confirming the
        # spike's warning that available_actions is advisory and must never
        # be treated as a fixed/complete key set. Nothing in this module
        # reads available_actions at all, precisely to avoid that trap.
    },
}


def test_song_from_item_maps_all_fields():
    song = bridge.song_from_item(PLAYBACK_STATE["item"])
    assert song["title"] == "Red Right Hand - 2011 Remaster"
    assert song["artist"] == "Nick Cave & The Bad Seeds"
    assert song["album"] == "Let Love In (2011 Remaster)"
    assert song["duration"] == 370.573
    assert song["uri"] == "spotify:track:0jVo3e34A15l6MNu1O3cfa"
    # large and xlarge carry the identical URL in this real capture (the
    # spike noted this is common); xlarge still wins by COVER_SIZE_ORDER.
    assert song["cover_art_url"] == (
        "https://i.scdn.co/image/ab67616d0000b27399249d4ab96f4760017c40ae")


def test_song_from_item_tolerates_a_bare_entity():
    song = bridge.song_from_item({"uri": "spotify:track:x", "entity_type": "track"})
    assert song["title"] is None
    assert song["uri"] == "spotify:track:x"
    assert song["cover_art_url"] is None


def test_song_from_item_returns_none_for_no_item():
    assert bridge.song_from_item(None) is None


def test_best_cover_url_picks_the_largest_of_distinct_sizes():
    # The real PLAYBACK_STATE capture above has large == xlarge (same URL),
    # so it cannot by itself distinguish "picks the largest" from "picks
    # any of the top two". A synthetic fixture with four DISTINCT URLs
    # closes that gap (fix-round-1, Minor D).
    decorations = {"visual_identity": {"cover": [
        {"url": "https://example.com/small.jpg", "size": "small"},
        {"url": "https://example.com/default.jpg", "size": "default"},
        {"url": "https://example.com/large.jpg", "size": "large"},
        {"url": "https://example.com/xlarge.jpg", "size": "xlarge"},
    ]}}
    assert bridge.best_cover_url(decorations) == "https://example.com/xlarge.jpg"


def test_song_from_item_tolerates_explicit_nulls():
    # Real Soloist payloads have been observed to carry an explicit JSON
    # null for a key that is present but not populated (fix-round-1,
    # Important A/the reviewer's "playback": null repro). `.get(key, {})`
    # would raise on this -- only `.get(key) or {}` tolerates it -- because
    # the default in `.get(key, {})` only applies when the key is MISSING,
    # not when it is present with value None.
    item = {
        "uri": "spotify:track:nulltest",
        "decorations": {
            "identity": {"name": "Null Test"},
            "playback": None,
            "visual_identity": None,
            "parent": None,
            "creators": [None, {"entity": {"decorations": {"identity": {"name": "A"}}}}],
        },
    }
    song = bridge.song_from_item(item)
    assert song["title"] == "Null Test"
    assert song["duration"] is None
    assert song["cover_art_url"] is None
    assert song["album"] is None
    assert song["artist"] == "A"


def test_playback_state_expands_to_several_acr_events():
    events = bridge.translate(PLAYBACK_STATE)
    kinds = [e["type"] for e in events]
    assert "song_changed" in kinds
    assert "state_changed" in kinds
    assert "position_changed" in kinds
    assert "shuffle_changed" in kinds
    assert "loop_mode_changed" in kinds
    # Volume is never translated -- see the module docstring. The bridge
    # never syncs volume in either direction; the device volume is the only
    # control, pinned once at login by start-soloist.
    assert "volume_changed" not in kinds
    assert not any(k.startswith("volume") for k in kinds)

    state = next(e for e in events if e["type"] == "state_changed")
    assert state["state"] == "paused"
    position = next(e for e in events if e["type"] == "position_changed")
    assert position["position"] == 310.404


def test_playback_changed_maps_status():
    assert bridge.translate({"type": "playback_changed", "status": "paused"}) == [
        {"type": "state_changed", "state": "paused"}
    ]


def test_position_sync_converts_to_seconds():
    events = bridge.translate({
        "type": "position_sync",
        "position": {"position_ms": 90500, "timestamp_ms": 1, "speed": 1.0},
    })
    assert events == [{"type": "position_changed", "position": 90.5}]


def test_repeat_modes_map_to_acr_loop_modes():
    assert bridge.loop_mode_from_repeat("off") == "none"
    assert bridge.loop_mode_from_repeat("track") == "track"
    assert bridge.loop_mode_from_repeat("context") == "playlist"
    assert bridge.loop_mode_from_repeat("something-new") == "none"


def test_queue_changed_maps_upcoming_only():
    events = bridge.translate({
        "type": "queue_changed",
        "previous": [{"uid": "a", "item": {
            "decorations": {"identity": {"name": "Played Already"}}}}],
        "upcoming": [
            {"uid": "b", "source": "queue", "item": {
                "uri": "spotify:track:next",
                "decorations": {
                    "identity": {"name": "Next Song"},
                    "creators": [{"entity": {"decorations": {"identity": {"name": "A"}}}}],
                }}},
        ],
    })
    assert len(events) == 1
    queue = events[0]
    assert queue["type"] == "queue_changed"
    assert len(queue["queue"]) == 1
    assert queue["queue"][0]["title"] == "Next Song"
    assert queue["queue"][0]["artist"] == "A"
    assert queue["queue"][0]["uri"] == "spotify:track:next"


def test_volume_changed_produces_nothing():
    # Deliberate: Soloist attenuates in software (confirmed on hardware),
    # so double-attenuation risk means the bridge must never forward this.
    assert bridge.translate({"type": "volume_changed", "volume": 40}) == []


def test_unknown_event_produces_nothing():
    assert bridge.translate({"type": "something_unheard_of"}) == []


def test_error_event_produces_nothing():
    assert bridge.translate({"type": "error", "message": "boom"}) == []


def test_command_translation_covers_the_acr_vocabulary():
    assert bridge.soloist_command({"command": "play"}) == [{"type": "command", "command": "play"}]
    assert bridge.soloist_command({"command": "next"}) == [
        {"type": "command", "command": "skip_next"}]
    assert bridge.soloist_command({"command": "previous"}) == [
        {"type": "command", "command": "skip_prev"}]
    assert bridge.soloist_command({"command": "seek", "position": 12.5}) == [
        {"type": "command", "command": "seek", "position_ms": 12500}]
    assert bridge.soloist_command({"command": "set_shuffle", "shuffle": True}) == [
        {"type": "command", "command": "set_shuffle", "enabled": True}]


def test_no_command_ever_sets_volume():
    # Never send set_volume, for any input -- see the module docstring.
    for command in ("play", "pause", "stop", "next", "previous", "set_shuffle",
                     "set_loop_mode", "seek", "set_volume", "volume"):
        for message in bridge.soloist_command({"command": command, "position": 1,
                                                "shuffle": True, "loop_mode": "song",
                                                "volume": 50}):
            assert message["command"] != "set_volume"


def test_set_volume_command_is_explicitly_ignored():
    # fix-round-1, Minor C: the sweep above never exercises the
    # "set_volume"/"volume"/unknown branches, since soloist_command()
    # emits nothing for them and the inner loop body never runs -- so
    # those cases were previously untested despite being iterated over.
    # Make the intent explicit.
    assert bridge.soloist_command({"command": "set_volume", "volume": 50}) == []
    assert bridge.soloist_command({"command": "volume", "volume": 50}) == []


def test_stop_pauses_and_releases_the_device():
    # Soloist has no stop; pausing and deactivating is the graceful equivalent
    # of librespot's kill-the-unit behaviour, and keeps the device visible.
    assert bridge.soloist_command({"command": "stop"}) == [
        {"type": "command", "command": "pause"},
        {"type": "command", "command": "deactivate"},
    ]


def test_loop_mode_maps_to_the_right_repeat_command():
    assert bridge.soloist_command({"command": "set_loop_mode", "loop_mode": "song"}) == [
        {"type": "command", "command": "set_repeat_track", "enabled": True}]
    assert bridge.soloist_command({"command": "set_loop_mode", "loop_mode": "playlist"}) == [
        {"type": "command", "command": "set_repeat_context", "enabled": True}]
    assert bridge.soloist_command({"command": "set_loop_mode", "loop_mode": "no"}) == [
        {"type": "command", "command": "set_repeat_track", "enabled": False},
        {"type": "command", "command": "set_repeat_context", "enabled": False}]


def test_loop_mode_accepts_track_as_a_song_alias():
    # fix-round-1, Minor B: loop_mode_from_repeat() (our own outbound
    # translation) emits "track", matching ACR's documented
    # none|song|track|playlist vocabulary, so a caller echoing that value
    # back must round-trip to the same command as "song".
    assert bridge.soloist_command({"command": "set_loop_mode", "loop_mode": "track"}) == [
        {"type": "command", "command": "set_repeat_track", "enabled": True}]


def test_unknown_command_is_ignored():
    assert bridge.soloist_command({"command": "teleport"}) == []
