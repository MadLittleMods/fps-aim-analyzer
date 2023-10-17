## FPS aim analyzer

> [!WARNING]  
> This is a work in progress and basically does nothing at the moment. Just figuring out how to make a GUI and windows in X11 right now. This is just a toy project for me to learn Zig.

End-goal: Take a small screenshot around the reticle and display it in a Discord-style overlay in the corner for manual review and quick feedback. To answer the question: "Did I hit that shot?" and eliminate doubt when the server disagrees with your client view.

Further: In the future, it would be interesting to actually analyze whether the shot was actually on target but that seems dubious since the server decides whether you hit, not your client view. Probably will have to rely on hit markers as a good enough.

Mostly thinking about this in terms of Halo Infinite right now.

### Building and running

Tested with Zig 0.11.0

```
zig build run
```

![](https://github.com/MadLittleMods/fps-aim-analyzer/assets/558581/d5d7539d-f5f5-440d-9863-8bda58e1f68e)


### Dev notes

See the [*developer notes*](./dev-notes.md) for more information.
