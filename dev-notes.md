# Developer notes

A collection of references and notes while developing this project.

## X Window System, X11 protocol

In this project, we're using the [`zigx`](https://github.com/marler8997/zigx) project which is a pretty barebones wrapper around the X11 client protocol to communicate with the X11 server.

Documentation:

 - Protocol: https://www.x.org/releases/current/doc/xproto/x11protocol.html
 - `libx11` client library for C projects:
    - Docs: https://www.x.org/releases/current/doc/libX11/libX11/libX11.html
    - Source: https://gitlab.freedesktop.org/xorg/lib/libx11
 - `xcb` client library for C projects:
    - Docs: https://xcb.freedesktop.org/
    - Source: https://gitlab.freedesktop.org/xorg/lib/libxcb
    - Protocol XML definitions: https://gitlab.freedesktop.org/xorg/proto/xcbproto

Guides:

 - A walkthrough of using the X Window system, https://magcius.github.io/xplain/article/index.html

#### Extensions

See the note below on *"Finding installed extensions to the X.org server"* to discover all of what you can use.

In this project, we rely on the X Render Extension to handle the screenshot capturing from an opaque window and compositing it on top of our transparent window. With normal X operations, you can't mix different depths (24-bit RGB vs 32-bit ARGB).

 - The X Rendering Extension protocol docs:
    - https://www.keithp.com/~keithp/render/protocol.html
    - https://www.x.org/releases/X11R7.5/doc/renderproto/renderproto.txt
 - XML definitions of the protocol: https://gitlab.freedesktop.org/xorg/proto/xcbproto/-/blob/98eeebfc2d7db5377b85437418fb942ea30ffc0d/src/render.xml
 - C library: https://gitlab.freedesktop.org/xorg/lib/libxrender


#### Debugging

You can use `x11trace` to see the X11 protocol messages being sent and received by a program. At least on Manjaro Linux, you need to install the `xtrace` package to get the `x11trace` command. Confusingly, you might already have a `xtrace` command but that's not the same thing.

```sh
x11trace ./zig-out/bin/aim-analyzer
```

Determine the color depth of your window or the root window ([via StackOverflow](https://stackoverflow.com/a/12345678/1097920)):

```diff
  $ xdpyinfo
  screen #0:
    dimensions:    1366x768 pixels (361x203 millimeters)
    resolution:    96x96 dots per inch
    depths (7):    24, 1, 4, 8, 15, 16, 32
    root window id:    0x2b9
+   depth of root window:    24 planes
    number of colormaps:    minimum 1, maximum 1
    default colormap:    0x20
    default number of colormap cells:    256
    preallocated pixels:    black 0, white 16777215
    options:    backing-store NO, save-unders NO
    largest cursor:    64x64
    current input event mask:    0xda4033
      KeyPressMask             KeyReleaseMask           EnterWindowMask          
      LeaveWindowMask          KeymapStateMask          StructureNotifyMask      
      SubstructureNotifyMask   SubstructureRedirectMask PropertyChangeMask       
      ColormapChangeMask       
    number of visuals:    240
+   default visual id:  0x21
    visual:
+     visual id:    0x21
      class:    TrueColor
+     depth:    24 planes
      available colormap entries:    256 per subfield
      red, green, blue masks:    0xff0000, 0xff00, 0xff
      significant bits in color specification:    8 bits
  [...]
```

Finding installed extensions to the X.org server:

([via StackOverflow](https://askubuntu.com/questions/995954/how-to-list-extensions-of-x-server-in-ubuntu-16-04/995962#995962))
```sh
$ xdpyinfo -display :0 -queryExtensions | awk '/^number of extensions:/,/^default screen number/'
number of extensions:    28
    BIG-REQUESTS  (opcode: 133)
    Composite  (opcode: 142)
    DAMAGE  (opcode: 143, base event: 91, base error: 152)
    DOUBLE-BUFFER  (opcode: 145, base error: 153)
    DPMS  (opcode: 147)
    DRI2  (opcode: 155, base event: 119)
    DRI3  (opcode: 149)
    GLX  (opcode: 152, base event: 95, base error: 158)
    Generic Event Extension  (opcode: 128)
    MIT-SCREEN-SAVER  (opcode: 144, base event: 92)
    MIT-SHM  (opcode: 130, base event: 65, base error: 128)
    Present  (opcode: 148)
    RANDR  (opcode: 140, base event: 89, base error: 147)
    RECORD  (opcode: 146, base error: 154)
    RENDER  (opcode: 139, base error: 142)
    SECURITY  (opcode: 137, base event: 86, base error: 138)
    SHAPE  (opcode: 129, base event: 64)
    SYNC  (opcode: 134, base event: 83, base error: 134)
    X-Resource  (opcode: 150)
    XC-MISC  (opcode: 136)
    XFIXES  (opcode: 138, base event: 87, base error: 140)
    XFree86-DGA  (opcode: 154, base event: 112, base error: 179)
    XFree86-VidModeExtension  (opcode: 153, base error: 172)
    XINERAMA  (opcode: 141)
    XInputExtension  (opcode: 131, base event: 66, base error: 129)
    XKEYBOARD  (opcode: 135, base event: 85, base error: 137)
    XTEST  (opcode: 132)
    XVideo  (opcode: 151, base event: 93, base error: 155)
default screen number:    0
```


## Testing with multiple screens

> [!WARNING]  
> These steps don't actually seem to work to add another "screen" in terms of what the X Window Server sees. But still seem like useful commands to keep around until I do figure out how this all works.

Add a virtual monitor ([*courtesy of this GitHub issue*](https://github.com/pavlobu/deskreen/issues/42#issue-792962894)).

List available ports:
```sh
$ xrandr
Screen 0: minimum 320 x 200, current 3840 x 2160, maximum 16384 x 16384
DisplayPort-0 connected 3840x2160+0+0 (normal left inverted right x axis y axis) 878mm x 485mm
   3840x2160     60.00*+  30.00    30.00
   2560x1440     59.95
   1920x1200     60.00
   1920x1080     60.00    60.00    50.00    50.00    59.94
   1600x1200     60.00
   1680x1050     59.95
   1280x1024     75.02    60.02
   1440x900      74.98    59.89
   1280x960      60.00
   1280x800      60.00
   1280x720      60.00    50.00    59.94
   1024x768      75.03    60.00
   800x600       75.00    60.32
   720x576       50.00
   720x480       60.00    59.94
   640x480       75.00    72.81    66.67    60.00    59.94
   720x400       70.08
DisplayPort-1 disconnected (normal left inverted right x axis y axis)
DisplayPort-2 disconnected (normal left inverted right x axis y axis)
HDMI-A-0 disconnected (normal left inverted right x axis y axis)
   1920x1080     60.00
```

Add a virtual monitor:
```
xrandr --addmode HDMI-A-0 1920x1080
xrandr --output HDMI-A-0 --mode 1920x1080 --right-of DisplayPort-0
```

To disconnect the display:
```
xrandr --output HDMI-A-0 --off
```

List monitors:
```
xrandr --listmonitors
```

Other resources:

 - https://www.youtube.com/watch?v=N9KxpPyJMJA
