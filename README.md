
# TouchbarEmulator

The Touch Bar Emulator brings the full original Touch Bar experience to your Flexbar

<img width="3000" height="152" alt="touchbar1" src="https://github.com/user-attachments/assets/4e3b54c7-7a3d-4dec-917d-035f19d2c5ee" />
<img width="3000" height="152" alt="touchbar2" src="https://github.com/user-attachments/assets/9be8c8c4-8744-41e7-994d-38d5f6a137a3" />
<img width="3000" height="152" alt="touchbar3" src="https://github.com/user-attachments/assets/dd2ad4be-cd78-4f6e-a58b-473c2a34f3b6" />

macOS 27+ uses a nonactivating simulator host beneath the desktop at the outer
left edge of all screens. ScreenCaptureKit streams native 2× content (2170×60
pixels after cropping), and touch events go directly to Apple's service without
moving the desktop cursor. No virtual display is created. Display layout changes
reposition the host at the new outer edge.

Known tradeoff: Mission Control and transitions between Mission Control and
fullscreen Spaces can expose the host. This mode does not promise invisibility
in every system overview or transition. macOS 26 and earlier continue using the
native backend selected by FlexDesigner. The old virtual display helper mode
remains available for explicit diagnostics; it is not an automatic fallback.

## Installation


### **Prerequisites**

- Node.js 18 or later  
- FlexDesigner v1.0.0 or later  
- A Flexbar device 
- Install FlexCLI  
  ```
  npm install -g @eniac/flexcli
  ```

### Clone & Setup

```
git clone https://github.com/chino-2333/Flexbar-TouchbarEmulator.git
cd Flexbar-TouchbarEmulator
npm install
```

## Debug

```
npm run dev
```

## Build & Pack

```
npm run build
npm run plugin:pack
```
  

The macOS helper build requires Xcode (including the original Apple Touch Bar
simulator XPC) and a code-signing identity. Release automation publishes the
committed, signed `.flexplugin` package after checking its version and SHA-256.
