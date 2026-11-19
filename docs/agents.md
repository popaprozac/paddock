# Agents, screenshots and input

## Agents over MCP

`paddock mcp` is an MCP server that an agent's client starts and talks to over stdin and stdout.
It reaches VMs as the other commands do: through this Mac's `serve`, or, on a Mac logged in to a
control plane, through its pool, so it runs on any logged-in Mac. Without a control plane, start
it on the `serve` Mac through ssh, which must log in without a prompt, with a key: an MCP client
can't answer a password prompt. In Claude Code, for example:

```bash
claude mcp add paddock -- ~/code/paddock/.build/out/Products/Release/paddock mcp                 # on the Mac
claude mcp add paddock -- ssh you@studio.local code/paddock/.build/out/Products/Release/paddock mcp  # from another
```

| Tool | What it does |
| --- | --- |
| `acquire` | Takes a warm VM from `serve`, or from the pool on a Mac logged in to a control plane, waiting while the slots fill. `allow` lists the names it may reach on the userspace network. |
| `screenshot` | The VM's screen as a PNG. |
| `accessibility_tree` | The focused app's accessibility tree as JSON, as `paddock axtree` prints it but on one line. |
| `click`, `type_text`, `press_keys`, `scroll` | Input, as with the commands of the same names (see [Input](#input)). |
| `run_command` | Runs a command as `paddock exec` does and returns its output and exit status. Output past 20,000 characters is cut to its last lines. After `timeout` seconds, 120 by default and at most 3,600, it returns what the command printed so far, and the command goes on running in the VM. |
| `release` | Hands the VM back to `serve`, which wipes it. |

- A session holds one VM at a time. When the client closes stdin, or stops the server with
  SIGINT, SIGTERM or SIGHUP, as a dropped ssh connection does, the server releases the VM it
  holds.
- Through a control plane, a session keeps one link open for all its tool calls. If the link
  drops, as when the control plane restarts, a call that was under way fails with the reason, and
  the next call opens a new link. paddock doesn't repeat a call on its own, since repeating a
  command, a click or an acquire could do it twice.
- Screenshots are scaled to fit 1280x800, keeping the screen's shape: 1920x1200 becomes
  1280x800. Every coordinate the tools take or return is in the screenshot's pixels, frames in
  the accessibility tree included, and the server converts them for the guest.
- What the tools return from the guest, its screen, tree and command output, is whatever the
  workload in the VM put there. An agent should trust it no more than the workload.

## Screenshots

`paddock screenshot` reads a VM's screen on the host, not in the guest. `serve` attaches a
`VZVirtualMachineView` to the VM, in a borderless window it places off every display, and copies
the frame that the view's framebuffer view keeps as an IOSurface. The guest needs no Screen
Recording permission, and paddock opens no listener and asks for no permission on the host. A
frame is the VM's display at its size in pixels, 1920×1200 by default, with the mouse pointer.
The first screenshot of a VM attaches the view and took about 150 ms in testing; later ones took
about 50 ms, mostly encoding the PNG.

- `serve` needs the window server for this, so start it from a logged-in session on the Mac. A
  `serve` that can't reach the window server refuses screenshots.
- Apple doesn't document that the view keeps its frame as an IOSurface. If a macOS release
  changes that, `screenshot` fails with an error saying what it couldn't find.
- The guest sends a frame only when its screen changes, so `serve` attaches each restored VM's
  display before the VM resumes and draws. A guest that doesn't redraw as it resumes still shows
  a black screen until its screen next changes: 2 of 10 hand-outs in testing.

## Taking a VM over by hand

`paddock show <vm>`, on the Mac whose `serve` runs the VM, moves its window on screen for a
person: titled, resizable and taking the mouse and keyboard, with the guest's resolution kept
and the window scaled down only to fit the display, so an agent's coordinates stay right.
While it's on screen:

- Input from agents and the CLI (`click`, `type`, `key`, `scroll`, and MCP's input tools) is
  refused with the reason, so a person and an agent don't share one pointer. Screenshots, the
  accessibility tree and commands go on, so an agent can watch.
- paddock shows in the Dock; clicking it brings the window to the front.
- `paddock hide <vm>`, closing the window or quitting paddock from the Dock or its menu hands
  the VM back: the window goes off screen at the guest's size and agents' input goes through
  again. The VM runs throughout, and `serve` keeps serving. Logging out, restarting or shutting
  down still stop `serve`. Force Quit stops `serve` and every slot with it, since it can't be
  caught.
- The VM's process uses more CPU while its window is drawn on screen: about 19% of a core,
  against about 5% off screen, in testing.

Only the Mac running a VM can show it; seeing one from another Mac isn't built yet.

## Input

`click`, `type`, `key` and `scroll` drive the guest from the host. `serve` sends mouse and
keyboard events to the `VZVirtualMachineView` it attaches for screenshots, and the guest gets them
from its virtual pointer and keyboard, so the guest grants nothing and runs nothing for them. A
command returns once its events are sent, not once the guest has acted on them; read the screen
or the accessibility tree to see the result. While a person has the VM on screen with
`paddock show`, they're refused, with the reason, until the VM is handed back.

- `type` and `key` press keys of a US keyboard, so the guest must use a US keyboard layout for
  text to come out as typed, and `type` refuses characters a US keyboard can't type, such as
  `é`. Apps still apply their own changes: TextEdit turns straight quotes into curly ones.
- A combination for `key` is modifiers and one key joined by `+`: modifiers are `cmd`, `ctrl`,
  `opt` and `shift`, and the key is a character, `plus` for `+`, or one of `return`, `tab`,
  `space`, `delete`, `forwarddelete`, `escape`, `left`, `right`, `up`, `down`, `home`, `end`,
  `pageup`, `pagedown` and `f1` to `f12`.
- Keys go at about 100 characters a second. The guest drops keys that go down and up much
  faster: typing 500 characters with no pause between key events, 163 arrived in testing.
- `scroll` directions are the content's with macOS's default natural scrolling. A golden image
  that turns natural scrolling off scrolls the other way.
