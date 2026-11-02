# Dockboard

Experimental minimize animation from iOS 27 SpringBoard.

**Original**

https://github.com/user-attachments/assets/699e7503-f5a5-408c-b9e3-89466b9853a0

**Dockboard**

https://github.com/user-attachments/assets/5e3932ae-9fd8-4dda-92f4-4b52d94786ef

Requires Apple silicon, macOS build **26B123**, **SIP disabled**, Xcode Command Line Tools, and Python 3. Other macOS builds are rejected.

```sh
make
open build/Dockboard.app
```

Choose **Dockboard** to enable, or **macOS Default** to revert. Quitting Dockboard leaves the current animation active; restarting Dock or logging out removes the runtime patches.

```sh
make test analyze
```
