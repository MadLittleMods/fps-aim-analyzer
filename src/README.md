## FPS aim analyzer

> [!WARNING]  
> This is a work in progress and basically does nothing at the moment. Just figuring out how to make a GUI and windows in X11 right now.

End-goal: Take a small screenshot around the reticle and display it in a discord-style overlay on the side for manual review.

Further: In the future, it would be interesting to actually analyze whether the shot was actually on target but that seems dubious since the server decides whether you hit, not your client view. Probably will have to rely on hit markers as a good enough.

### Building and running

Tested with Zig 0.11.0

```
zig build run
```
