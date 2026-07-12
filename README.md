# ReShade Cinematic Depth of Field (CinematicDoF)

A lightweight, highly optimized screen-space Depth of Field (DoF) shader for ReShade. Designed to deliver a high-quality cinematic bokeh effect with minimal performance impact.

## Features

- **Dominant-Object Autofocus**: Intelligently locks onto the largest/most dominant surface area in the focus zone, ignoring small foreground obstacles (like crosshairs, leaves, or thin particles) to eliminate focus jitter.
- **Full Auto Mode (Dynamic DoF)**: Dynamically scales the aperture/blur strength depending on focus distance. Near shots receive shallow depth-of-field/strong bokeh, while landscapes and wide-angle shots stay sharp automatically.
- **Vogel Spiral Sampling**: Employs a golden-angle Vogel spiral sampling pattern (16 samples) to construct smooth, circular bokeh disks without the overhead of heavy convolution.
- **Chromatic Aberration**: Simulates realistic lens diffraction by dynamically fringing out-of-focus edges based on local Circle of Confusion (CoC).
- **Highlight Boost**: Highlights out-of-focus bright spots to generate defined, glowing bokeh shapes.
- **Leak Prevention**: Advanced depth weighting prevents blurred background colors from leaking onto sharp foreground silhouettes.

## Installation

1. Copy [CinematicDoF.fx](CinematicDoF.fx) into your ReShade `Shaders` directory (usually located inside your game's root directory under `reshade-shaders\Shaders\`).
2. Open the ReShade overlay in-game and enable `CinematicDoF`.

## Configuration Options

- **Focus Speed**: Speed at which the autofocus transitions between different depth planes.
- **Aperture (DoF Strength)**: Core control for the strength of the blur effect.
- **Max Blur Radius**: Maximum screen-space size of the bokeh disks.
- **Autofocus Zone Size**: Size of the central screen region analyzed for autofocus.
- **Show Autofocus Zone**: Visual toggle to render the autofocus boundary rectangle.
- **Full Auto Mode (Dynamic DoF)**: Enable dynamic bokeh strength scaling based on distance.
- **Chromatic Aberration**: Strength of the color-fringing effect on blurred edges.
- **Highlight Boost**: Brightness amplification factor for out-of-focus highlights.
- **Highlight Threshold**: Luminance limit above which highlights are boosted.

## Author

- **M. Naufal Alwy**

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
