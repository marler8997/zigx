
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
