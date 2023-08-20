# zigx

An x11 client library for Zig applications.

Currently tested with zig version `0.11.0-dev.3132+465272921`.

# What you should know about X

X is a protocol for transmitting graphics primitives and user inputs.

## Components

XClient - a program that connects to an XServer to send graphics primitives and receive user inputs

XServer - a program that accepts XClients to receive graphics primitives and send user inputs

## The `DISPLAY` environment variable

XClient libraries use the `DISPLAY` environment variable to know how to connect to the XServer.  It uses this format:

```
[PROTOCOL/]HOST:DISPLAYNUM[.SCREEN]
```

Examples:

```
# connect to localhost port 6000
:0

# connect to host "foo" port 6003
foo:3

# connect to host "foo" port 6007 screen 5
foo:7.5
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
xtrace -n -- zig run example.zig
```

# Authentication

https://en.wikipedia.org/wiki/X_Window_authorization

I have yet to implement "cookie-based access".  To do so, I need to read the
cookie from `$HOME/.Xauthority` (or the file from environment variable
`XAUTHORITY` if it exists).  According to the wiki there are 2 methods
to sending the cookie, `MIT-MAGIC-COOKIE-1` and `XDM-AUTHORIZATION-1`.
In the first method the client simply sends the cookie when requested
to authenticate, in the second method a secret key is also stored in the
`.Xauthority` file, the client creates a string by concatenating the
current time, a transport identifier and the cookie, then encrypts
the resulting string and sends it to the server.
