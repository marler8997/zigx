# zigx

An x11 client library for Zig applications.

# What you should know about X

X is a protocol for transmitting graphics primitives and user inputs. It's a client/server model. X clients are typically programs that connect to a server.  Once connected, the client program will continually receive "user inputs" from the server (like keyboard/mouse events) and send drawing instructions. X has many extensions but the core specification is found here: https://www.x.org/docs/XProtocol/proto.pdf

## The `DISPLAY` environment variable

XClient libraries use the `DISPLAY` environment variable to know how to connect to the XServer.  It uses this format:

```
[PROTOCOL/][HOST]:DISPLAYNUM[.SCREEN]
```

Examples:

```
# connect to unix socket at /tmp/.X11-unix/X0
:0

# connect to "localhost" on port 6003
localhost:3

# connect to myserver port 6007 screen 5
myserver:7.5
```

Here are some examples of starting XClient programs and settings the `DISPLAY` environment variable:

```
# set the XSever
export DISPLAY=:0

# start a couple XClient programs
./my-cool-x-program &
./another-cool-x-program &

# start this program and connect it to the XServer on host "mymachine" running on port 6010 screen 1
DISPLAY=mymachine:10.1 ./yet-another-x-program
```

# How to debug an X connection

```
# -n means do not copy credentials
xtrace -n -- command

# i.e.
xtrace -n -- zig build hello
```

# Authentication

Authentication credentials are stored in a file in a binary format. The default path is `$HOME/.Xauthority` but can be overriden with the `XAUTHORITY` environment variable.

This binary file contains a list of credentials. Each entry can contain both an address and/or display number to that indicate which server the authorization applies to. Afterwards it contains a name/data pair to be exchanged with the server for authorization. You can build and use the `xauth` cli program to list the contents of one of these files, i.e.

```
zig build xauth -- list
```

https://en.wikipedia.org/wiki/X_Window_authorization

* `MIT-MAGIC-COOKIE`: implemented for local connections
* `XDM-AUTHORIZATION-1`: not implemented

For `XDM-AUTHORIZATION-1`, a secret key is stored in the `$HOME/.Xauthority` file, the client creates a string
by concatenating the current time, a transport identifier and the key, then encrypts the resulting string
and sends it to the server.
