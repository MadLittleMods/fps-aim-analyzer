# Developer notes

A collection of references and notes while developing this project.

## X Window System, X11 protocol

In this project, we're using the [`zigx`](https://github.com/marler8997/zigx) project
which is a pretty barebones wrapper around the X11 client protocol to communicate with
the X11 server.

Documentation:

 - Protocol: https://www.x.org/releases/current/doc/xproto/x11protocol.html
 - `libx11` client library for C projects:
    - Docs: https://www.x.org/releases/current/doc/libX11/libX11/libX11.html
    - Source: https://gitlab.freedesktop.org/xorg/lib/libx11
 - `xcb` client library for C projects:
    - Docs: https://xcb.freedesktop.org/
    - Source: https://gitlab.freedesktop.org/xorg/lib/libxcb

Guides:

 - A walkthrough of using the X Window system, https://magcius.github.io/xplain/article/index.html

#### Extensions

See the note below on *"Finding installed extensions to the X.org server"* to discover all of what you can use.

In this project, we rely on the X Render Extension to handle the screenshot capturing
from an opaque window and compositing it on top of our transparent window. With normal X
operations, you can't mix different depths (24-bit RGB vs 32-bit ARGB).

 - The X Rendering Extension protocol docs:
    - https://www.keithp.com/~keithp/render/protocol.html
    - https://www.x.org/releases/X11R7.5/doc/renderproto/renderproto.txt
 - XML definitions of the protocol:
   https://gitlab.freedesktop.org/xorg/proto/xcbproto/-/blob/98eeebfc2d7db5377b85437418fb942ea30ffc0d/src/render.xml
 - C library: https://gitlab.freedesktop.org/xorg/lib/libxrender


#### Debugging

You can use `x11trace` to see the X11 protocol messages being sent and received by a
program. At least on Manjaro Linux, you need to install the `xtrace` package to get the
`x11trace` command. Confusingly, you might already have a `xtrace` command but that's
not the same thing.

```sh
x11trace ./zig-out/bin/aim-analyzer
```

Determine the color depth of your window or the root window ([via
StackOverflow](https://stackoverflow.com/a/12345678/1097920)):

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


## Test with multiple X11 displays

> As far as the X window system is concerned, a display is a logical entity to which
> applications can connect and on which they can display windows, receive input, and do a
> few other things. A display can have multiple monitors, or can be connected to a virtual
> "monitor" that is not a physical device, for example a network connection for remote
> displays.
>
> *-- [Gilles on StackOverflow](https://unix.stackexchange.com/questions/667482/understanding-the-output-of-xrandr-query/667523#667523)*

Relevant tools:

 - `Xvfb`: X virtual framebuffer
    - Also `xvfb-run` to run a command in a virtual framebuffer (this will start and stop xvfb for you)
    - `xvfb-run --server-num 99 --server-args "-ac -screen 0 1920x1080x24" firefox`: Run Firefox in
      a virtual framebuffer with a 1920x1080 screen with 24-bit color depth.
 - `Xephyr`: Nested X server that runs as an X application. It's basically a way to
   create a new X11 screen that appears as a window on your desktop.
    - `Xephyr :99 -screen 1920x1080x24`: Creates a new 1920x1080 screen with 24-bit
      color depth. Then you can run `DISPLAY=:99 firefox` to run Firefox on that screen.
    - `xdpyinfo -display :99` to see the display info.
 - https://github.com/a-ba/squint/: `squint` is command that duplicates the output of a monitor into a X11 window.
 - https://github.com/Xpra-org/xpra/: Has the ability to access existing desktop sessions via it's [shadowing feature](https://github.com/Xpra-org/xpra/blob/master/docs/Usage/Shadow.md).
    - `xpra attach :99`: See an existing X11 session
    - `xpra shadow :99`: start a shadow server (not necessary on the same machine since you can just `attach` to it directly) https://github.com/Xpra-org/xpra/issues/3320#issuecomment-955442713
    - `xpra shadow ssh:DISPLAY_user@example.com:DISPLAY_number` https://wiki.archlinux.org/title/Xpra#Shadow_remote_desktop
 - https://looking-glass.io/: This is used for VM's but might be useful to peak on things

On Manjaro (Arch-based), you can install these with:
```
pamac install xorg-server-xvfb
pamac install xorg-server-xephyr
pamac install xpra
```

Examples:

Using `Xephyr`:

(run these commands in separate terminals or put them in the background with `&`)
```sh
# Create a new screen with Xephyr
Xephyr :99 -screen 1920x1080x24

# Start an application in the new screen
DISPLAY=:99 firefox

# See the existing screen
xpra attach :99
```

Using `Xvfb`:

```sh
# Create a new screen with Xvfb
Xvfb :99 -s -ac -screen 0 1920x1080x24
# Start an application in the new screen
DISPLAY=:99 firefox

# Alternatively, you can use `xvfb-run` to do the same thing
xvfb-run --server-num 99 --server-args "-ac -screen 0 1920x1080x24" firefox

# Start the shadow server (unlike `Xephyr`, the shadow server seems to be necessary to
# be able to connect successfully probably because it's not considered a
# "desktop"/"seamless" xpra session)
xpra shadow :99
# See the existing screen
xpra attach :99
```

## Testing with multiple monitors

> [!WARNING]  
> These steps don't actually seem to work to add another "screen" in terms of what the X
> Window Server sees. But still seem like useful commands to keep around until I do
> figure out how this all works.

A display in X11 can be made up of multiple monitors.

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
xrandr --addmode VIRTUAL1 1920x1080
xrandr --output VIRTUAL1 --mode 1920x1080 --right-of DisplayPort-0
```

To disconnect the display:
```
xrandr --output VIRTUAL1 --off
```

List monitors:
```
xrandr --listmonitors
```

Other resources:

 - https://www.youtube.com/watch?v=N9KxpPyJMJA


## Setup SSH X11 forwarding

This will allow you to run GUI applications on a remote server and direct the
display to a client machine.

This is *NOT* for viewing already-running applications on the server.

---

On the **server**, edit your SSH daemon config (`/etc/ssh/sshd_config`):
```
X11Forwarding yes
```

Restart the SSH daemon on the **server** after changing the config:

```sh
sudo systemctl restart sshd
```

On the **client**, you could add `ForwardX11 yes` to your SSH config (`~/.ssh/config` or
`/etc/ssh/ssh_config`) but it's easier just to use the flags when you connect:
```ssh
# -X Enables X11 forwarding
# (treat the remote machine that you're connecting to as untrusted to protect yourself from malicious commands)
ssh -X eric@eric-desktop-pc

# -Y Enables trusted X11 forwarding
#
# See if your use case works with `-X` first as the trusted option marks the remote
# machine that you're connecting to as trusted which allows them to use some of the
# scarier commands that would allow them to sniff data from the remote machine (make
# screenshots, do keylogging and other nasty stuff) and even alter data on your machine.
ssh -Y eric@eric-desktop-pc
```

Then you can run GUI applications on the server and they will display on your client machine.

References:

 - https://unix.stackexchange.com/questions/12755/how-to-forward-x-over-ssh-to-run-graphics-applications-remotely/12772#12772
 - https://wiki.archlinux.org/title/OpenSSH#X11_forwarding
 - https://www.dedoimedo.com/computers/xephyr.html
