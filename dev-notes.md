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
    - Protocol XML definitions: https://gitlab.freedesktop.org/xorg/proto/xcbproto

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

For other tools, the first thing you'll need is the window ID. One easy option is to use
`xwininfo` to find the window ID of a window:
```sh
# Run this command and click on the window to get the window ID and a bunch of other info
xwininfo

# Get the window tree
xwininfo -root -tree

# Get the window ID of the window under the cursor
xdotool getmouselocation
```

You can use `xev` to monitor X events (you can use the hex or decimal version of the window ID).

```sh
# Listen for events for the specific window ID
xev -id 0xcc00003
```

`xev` has an `-event` mask option but it only works as an allowlist, not a
denylist. We can use `awk` to filter out and exclude the events that are really noisy.
```sh
xev -id 0xd000003 | awk '/^(MotionNotify|KeyPress|KeyRelease|KeymapNotify|EnterNotify|LeaveNotify|FocusIn|FocusOut)/ {skip=1} skip==1 && NF==0 {skip=0; next} !skip'
```

Explaination of the `awk` command:

 1. `/^(MotionNotify|KeyPress|KeyRelease|KeymapNotify|EnterNotify|LeaveNotify|FocusIn|FocusOut)/ {skip=1}`
    - This pattern matches lines starting with any of the specified event types.
    - When a match is found, it sets the skip variable to `1`.
 1. `skip==1 && NF==0 {skip=0; next}`
    - This condition checks if `skip` is `1` (we're in skipping mode) and if the current line is empty (`NF==0`).
    - If both are true, it sets `skip` back to `0` and uses next to move to the next line without printing.
    - This effectively skips the empty line that ends the block we want to omit.
 1. `!skip`
    - This is the condition for printing a line.
    - It prints the line if skip is `0` (false).
    - When `skip` is 1, this condition is false, so lines are not printed.


You can use `xprop` to get the properties of a window. These are more relevant when
running with a window manager that will pick up these hints and apply them to the
window.
```sh
# Example is from a borderless fullscreen Halo Infinite window
# (notice `_NET_WM_STATE_FULLSCREEN`, and `_NET_FRAME_EXTENTS = 0, 0, 0, 0`)
$ xprop -id 0xd000003
_NET_WM_ICON_GEOMETRY(CARDINAL) = 1810, 2100, 60, 60
_NET_FRAME_EXTENTS(CARDINAL) = 0, 0, 0, 0
_NET_WM_ALLOWED_ACTIONS(ATOM) = _NET_WM_ACTION_CLOSE, _NET_WM_ACTION_ABOVE, _NET_WM_ACTION_BELOW, _NET_WM_ACTION_FULLSCREEN, _NET_WM_ACTION_MOVE, _NET_WM_ACTION_CHANGE_DESKTOP, _NET_WM_ACTION_STICK
WM_STATE(WM_STATE):
                window state: Normal
                icon window: 0x141aa700
_NET_WM_DESKTOP(CARDINAL) = 0
_NET_WM_ICON(CARDINAL) =        Icon (16 x 16):
        ████████████████████████████████
        ████████████████████████████████
        ████████████████████████████████
        ████████████████████████████████
        ████████████████████████████████
        ████████████████████████████████
        ████████████████████████████████
        ████████████████████████████████
        ████████████████████████████████
        ████████████████████████████████
        ████████████████████████████████
        ████████████████████████████████
        ████████████████████████████████
        ████████████████████████████████
        ████████████████████████████████
        ████████████████████████████████


_NET_WM_BYPASS_COMPOSITOR(CARDINAL) = 1
_NET_WM_STATE(ATOM) = _NET_WM_STATE_FULLSCREEN
_NET_WM_NAME(UTF8_STRING) = "Halo Infinite"
WM_ICON_NAME(STRING) = "Halo Infinite"
WM_NAME(STRING) = "Halo Infinite"
_WINE_HWND_EXSTYLE(CARDINAL) = 0
_WINE_HWND_STYLE(CARDINAL) = 335544320
WM_HINTS(WM_HINTS):
                Client accepts input or input focus: True
                Initial state is Normal State.
                bitmap id # to use for icon: 0xdc00023
                bitmap id # of mask for icon: 0xdc00025
                window id # of group leader: 0xde00003
_NET_WM_WINDOW_TYPE(ATOM) = _NET_WM_WINDOW_TYPE_NORMAL
_MOTIF_WM_HINTS(_MOTIF_WM_HINTS) = 0x3, 0x26, 0x0, 0x0, 0x0
WM_NORMAL_HINTS(WM_SIZE_HINTS):
                program specified location: 0, 0
                window gravity: Static
_NET_WM_USER_TIME_WINDOW(WINDOW): window id # 0xdc00012
XdndAware(ATOM) = BITMAP
_NET_WM_PID(CARDINAL) = 925027
WM_LOCALE_NAME(STRING) = "en_US.UTF-8"
WM_CLIENT_MACHINE(STRING) = "some-pc"
WM_CLASS(STRING) = "steam_app_1240440", "steam_app_1240440"
WM_PROTOCOLS(ATOM): protocols  WM_DELETE_WINDOW, _NET_WM_PING
STEAM_GAME(CARDINAL) = 1240440
```

##### Determine the color depth of your window or the root window

([via
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

##### Finding installed extensions to the X.org server:

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

Find which versions of the extensions that you have:
```sh
$ dpyinfo -ext all | grep version
version number:    11.0
X.Org version: 21.1.13
Xlib:  extension "Multi-Buffering" missing on display ":0.0".
MIT-SHM version 1.2 opcode: 130, base event: 65, base error: 128
XKEYBOARD version 1.0 opcode: 135, base event: 85, base error: 137
SHAPE version 1.1 opcode: 129, base event: 64
SYNC version 3.1 opcode: 134, base event: 83, base error: 134
XFree86-VidModeExtension version 2.2 opcode: 153, base error: 172
XTEST version 2.2 opcode: 132
DOUBLE-BUFFER version 1.0 opcode: 145, base error: 153
RECORD version 1.13 opcode: 146, base error: 154
XInputExtension version 2.4 opcode: 131, base event: 66, base error: 129
RENDER version 0.11 opcode: 139, base error: 142
Composite version 0.4 opcode: 142
XINERAMA version 1.1 opcode: 141
```


### The `DISPLAY` environment variable

XClient libraries use the DISPLAY environment variable to know how to connect to the XServer. It uses this format:

```
[PROTOCOL/]HOST:DISPLAYNUM[.SCREEN]
```

Examples:

```
# connect to localhost port 6000, display 0
:0

# connect to localhost port 6000, display 0,
# screen 0
:0.0
# screen 1
:0.1

# connect to host "foo" port 6003, display 3
foo:3

# connect to host "foo" port 6007, display 7, screen 5
foo:7.5
```



### Test with multiple X11 displays

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
      a virtual framebuffer with a 1920x1080 display with 24-bit color depth.
 - `Xephyr`: Nested X server that runs as an X application. It's basically a way to
   create a new X11 screen that appears as a window on your desktop.
    - `Xephyr :99 -screen 1920x1080x24`: Creates a new 1920x1080 display with 24-bit
      color depth. Then you can run `DISPLAY=:99 firefox` to run Firefox on that display.
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
# Create a new display with Xephyr
Xephyr :99 -screen 1920x1080x24

# Start an application in the new display
DISPLAY=:99 firefox

# You will already be able to see what's happening in the Xephyr window,
# but just as an example on using `xpra`, you can connect and watch an existing display
xpra attach :99
```

Using `Xvfb`:

```sh
# Create a new display with Xvfb
Xvfb :99 -s -ac -screen 0 1920x1080x24
# Start an application in the new screen
DISPLAY=:99 firefox

# Alternatively, you can use `xvfb-run` to do the same thing
xvfb-run --server-num 99 --server-args "-ac -screen 0 1920x1080x24" firefox

# Start the shadow server (unlike `Xephyr`, the shadow server seems to be necessary to
# be able to connect successfully probably because it's not considered a
# "desktop"/"seamless" xpra session)
xpra shadow :99
# See the existing display
xpra attach :99
```

Record the display with `ffmpeg`:

```sh
# Create a new display with Xvfb
Xvfb :99 -s -ac -screen 0 1920x1080x24
# Start an application in the new display
DISPLAY=:99 firefox

# Record the display with ffmpeg (press `q` to stop recording, using `Ctrl + c` (SIGINT)
# seems to corrupt the video file since it exits immediately)
ffmpeg -f x11grab -video_size 1920x1080 -i ":99" out.webm
```

## Testing with multiple monitors

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
