# Ken Burns Parallax Slideshow with Subject Isolation

## Research & Implementation Plan for FlowFinder

---

## Executive Summary

This document outlines a comprehensive plan for building a beautiful Ken Burns slideshow view with parallax effects, leveraging Apple's subject isolation ("cutout") technology and depth/3D photo capabilities. The goal is to create a cinematic photo viewing experience where foreground subjects appear to float above backgrounds with subtle parallax motion.

---

## Table of Contents

1. [Core Concepts](#core-concepts)
2. [Apple Frameworks & APIs](#apple-frameworks--apis)
3. [Subject Isolation Deep Dive](#subject-isolation-deep-dive)
4. [Depth Data & Spatial Photos](#depth-data--spatial-photos)
5. [Ken Burns Effect Implementation](#ken-burns-effect-implementation)
6. [Parallax Effect Architecture](#parallax-effect-architecture)
7. [Implementation Plan](#implementation-plan)
8. [Code Examples](#code-examples)
9. [Performance Considerations](#performance-considerations)
10. [Platform Availability](#platform-availability)

---

## Core Concepts

### What is Ken Burns Effect?

The Ken Burns effect is a cinematic panning and zooming technique named after documentary filmmaker Ken Burns. It involves:
- **Slow pan** across an image (translation)
- **Gradual zoom** in or out (scale)
- **Smooth transitions** between keyframes
- Creates a sense of motion and life in still photographs

### What is Parallax?

Parallax creates depth perception by moving foreground and background elements at different speeds:
- **Foreground elements** move faster/more prominently
- **Background elements** move slower/subtly
- Creates an illusion of 3D depth in a 2D composition

### The Vision: Combining Both

By isolating the subject (person, object) from the background, we can:
1. Apply Ken Burns pan/zoom to the background layer
2. Apply a different (or no) transformation to the foreground subject
3. Create a stunning parallax effect where subjects appear to "pop" from the scene

---

## Apple Frameworks & APIs

### Primary Frameworks

| Framework | Purpose | Availability |
|-----------|---------|--------------|
| **Vision** | Subject isolation, saliency detection | iOS 17+, macOS 14+ |
| **VisionKit** | Easy subject lifting UI | iOS 17+, macOS 14+ |
| **AVFoundation** | Depth data, portrait mattes | iOS 12+, macOS 10.14+ |
| **Core Image** | Image compositing, blending | iOS 5+, macOS 10.4+ |
| **Core Animation** | Keyframe animations | iOS 2+, macOS 10.5+ |
| **PhotoKit** | Photo library access | iOS 8+, macOS 10.13+ |
| **ImageIO** | Spatial photo metadata | iOS 17+, macOS 14+ |

### Key APIs by Function

#### Subject Isolation
- `VNGenerateForegroundInstanceMaskRequest` - Generate foreground masks
- `VNInstanceMaskObservation` - Contains instance mask data
- `VNGeneratePersonInstanceMaskRequest` - Person-specific masks
- `ImageAnalysisInteraction` (VisionKit) - Easy subject lifting

#### Depth & Portrait Data
- `AVDepthData` - Depth map data from photos
- `AVPortraitEffectsMatte` - High-res foreground/background separation
- `AVSemanticSegmentationMatte` - Hair, skin, teeth, glasses mattes

#### Saliency (Smart Panning)
- `VNGenerateAttentionBasedSaliencyImageRequest` - Where people look
- `VNGenerateObjectnessBasedSaliencyImageRequest` - Foreground objects
- `VNSaliencyImageObservation` - Bounding boxes for salient regions

#### Image Compositing
- `CIBlendWithMask` - Blend images using a mask
- `CIBlendWithAlphaMask` - Alpha-based blending
- `CIMaskToAlpha` - Convert mask to alpha channel

---

## Subject Isolation Deep Dive

### Vision Framework Approach (iOS 17+, macOS 14+)

The Vision framework provides the most powerful and flexible subject isolation capabilities.

#### VNGenerateForegroundInstanceMaskRequest

This is the primary API for subject isolation, introduced in iOS 17/macOS 14.

**Key Characteristics:**
- **Class-agnostic**: Works on any foreground object (people, pets, objects, buildings)
- **Multiple instances**: Can detect and separate multiple subjects
- **High resolution**: Output mask matches input image resolution
- **Instance labeling**: Each subject gets a unique index for selective extraction

**Process Flow:**
```
Input Image → Vision Request → Instance Mask Observation → Scaled Mask → Composite
```

**Output:**
- `VNInstanceMaskObservation` containing:
  - Instance mask (pixel buffer with labeled regions)
  - `allInstances` property (IndexSet of all foreground instance indices)
  - Methods to generate masks for specific instances

#### Instance Mask Concepts

1. **Instance Index 0**: Always represents the background
2. **Instance Index 1+**: Each foreground object gets sequential indices
3. **Soft Mask**: Floating-point values (0.0-1.0) for smooth edges
4. **Hit Testing**: Look up pixel value to determine which instance was tapped

### VisionKit Approach (Easier, Limited)

VisionKit provides a simpler approach with built-in UI:

```swift
// Add subject lifting to any image view
let interaction = ImageAnalysisInteraction()
interaction.preferredInteractionTypes = .imageSubject
imageView.addInteraction(interaction)
```

**Limitations:**
- Out-of-process execution (image size limited)
- Less control over the masking process
- Tied to a view

### Portrait Effects Matte (iOS 12+)

For photos captured in Portrait mode, a high-resolution matte is embedded:

**Advantages:**
- Higher quality than real-time Vision processing
- Pre-computed by Apple's neural network
- Optimized for people
- Includes fine details like hair

**Available Matte Types:**
| Type | Description |
|------|-------------|
| `portraitEffectsMatte` | Full person segmentation |
| `hair` | Hair region only |
| `skin` | Skin region only |
| `teeth` | Teeth region only |
| `glasses` | Glasses region only |

---

## Depth Data & Spatial Photos

### AVDepthData (iOS 11+)

Photos captured with dual cameras or TrueDepth contain depth maps:

**Dual Camera (Back):**
- Uses parallax between two cameras
- Measures disparity (1/meters)
- Relative accuracy (good for effects, not absolute distance)

**TrueDepth Camera (Front):**
- Projects infrared pattern
- Can measure absolute depth in meters
- Higher accuracy for face-based effects

**Accessing Depth Data:**
```swift
// From PHAsset
let options = PHImageRequestOptions()
// Request the image data
imageManager.requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
    if let data = data,
       let source = CGImageSourceCreateWithData(data as CFData, nil) {
        // Extract auxiliary depth data
        let depthData = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
            source, 0, kCGImageAuxiliaryDataTypeDepth
        )
    }
}
```

### Spatial Photos (iOS 17+, visionOS)

Apple's new spatial photo format for Vision Pro and iPhone 15 Pro:

**Structure:**
- Multi-image HEIC file
- Left-eye and right-eye stereo pair
- Spatial metadata for 3D presentation

**Spatial Metadata Components:**
1. **Horizontal Field of View** - Camera's visible width
2. **Baseline** - Distance between camera centers (typically ~64mm for "real-world" scale)
3. **Projection** - Always rectilinear
4. **Horizontal Disparity Adjustment** - Stereo depth tuning

**Use Cases for Slideshow:**
- Could render spatial photos with depth on visionOS
- Extract stereo pairs for pseudo-3D effect on 2D displays
- Use depth inference for parallax layer separation

---

## Ken Burns Effect Implementation

### Core Animation Approach

Use `CAKeyframeAnimation` for smooth, interpolated pan/zoom:

```swift
// Create keyframe animation for position (pan)
let positionAnimation = CAKeyframeAnimation(keyPath: "position")
positionAnimation.values = [
    NSValue(cgPoint: startPosition),
    NSValue(cgPoint: endPosition)
]
positionAnimation.keyTimes = [0, 1]
positionAnimation.duration = 8.0
positionAnimation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

// Create keyframe animation for scale (zoom)
let scaleAnimation = CAKeyframeAnimation(keyPath: "transform.scale")
scaleAnimation.values = [1.0, 1.3]  // 30% zoom
scaleAnimation.keyTimes = [0, 1]
scaleAnimation.duration = 8.0

// Group animations
let group = CAAnimationGroup()
group.animations = [positionAnimation, scaleAnimation]
group.duration = 8.0
```

### SwiftUI Approach

```swift
struct KenBurnsView: View {
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero

    var body: some View {
        Image("photo")
            .resizable()
            .scaleEffect(scale)
            .offset(offset)
            .onAppear {
                withAnimation(.easeInOut(duration: 8.0)) {
                    scale = 1.3
                    offset = CGSize(width: 50, height: -30)
                }
            }
    }
}
```

### Smart Panning with Saliency

Use Vision's saliency detection to determine WHERE to pan:

```swift
// Attention-based saliency - where people look
let request = VNGenerateAttentionBasedSaliencyImageRequest()
let handler = VNImageRequestHandler(cgImage: image)
try handler.perform([request])

if let observation = request.results?.first as? VNSaliencyImageObservation,
   let boundingBox = observation.salientObjects?.first?.boundingBox {
    // boundingBox is in normalized coordinates (0-1)
    // Use this to determine pan start/end points
    let panTarget = CGPoint(
        x: boundingBox.midX * imageWidth,
        y: boundingBox.midY * imageHeight
    )
}
```

**Saliency Types:**
| Type | Best For |
|------|----------|
| Attention-based | What draws the eye (faces, contrast) |
| Object-based | Foreground objects for cropping |

---

## Parallax Effect Architecture

### Multi-Layer Composition

The core architecture separates an image into layers that move independently:

```
┌─────────────────────────────────────────┐
│              Final Composite            │
├─────────────────────────────────────────┤
│  Layer 3: Foreground Subject(s)         │  ← Moves most / stays centered
│  Layer 2: Mid-ground (optional)         │  ← Moves medium amount
│  Layer 1: Background                    │  ← Moves least / Ken Burns
└─────────────────────────────────────────┘
```

### Layer Separation Strategy

#### Option 1: Vision Subject Mask (Recommended)

```swift
// 1. Generate foreground mask
let request = VNGenerateForegroundInstanceMaskRequest()
let handler = VNImageRequestHandler(cgImage: sourceImage)
try handler.perform([request])

guard let observation = request.results?.first as? VNInstanceMaskObservation else { return }

// 2. Create scaled mask for all foreground instances
let mask = try observation.createScaledMask(
    forInstances: observation.allInstances,
    from: handler
)

// 3. Use CoreImage to separate layers
let ciSource = CIImage(cgImage: sourceImage)
let ciMask = CIImage(cvPixelBuffer: mask)

// Foreground (subject)
let foreground = ciSource.applyingFilter("CIBlendWithMask", parameters: [
    kCIInputMaskImageKey: ciMask,
    kCIInputBackgroundImageKey: CIImage.empty()  // Transparent
])

// Background (inverted mask)
let invertedMask = ciMask.applyingFilter("CIColorInvert")
let background = ciSource.applyingFilter("CIBlendWithMask", parameters: [
    kCIInputMaskImageKey: invertedMask,
    kCIInputBackgroundImageKey: CIImage.empty()
])
```

#### Option 2: Portrait Effects Matte (For Portrait Photos)

```swift
// Extract portrait matte from photo data
if let source = CGImageSourceCreateWithData(photoData as CFData, nil),
   let matteData = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
       source, 0, kCGImageAuxiliaryDataTypePortraitEffectsMatte
   ) {
    let matte = try AVPortraitEffectsMatte(fromDictionaryRepresentation: matteData as! [String: Any])
    let mattePixelBuffer = matte.mattingImage
    // Use mattePixelBuffer as mask for separation
}
```

#### Option 3: Depth-Based Separation

```swift
// Use depth data to create layers at different distances
if let depthData = photo.depthData {
    let depthBuffer = depthData.depthDataMap

    // Threshold depth to create foreground/background masks
    // Pixels closer than threshold → foreground
    // Pixels farther than threshold → background
}
```

### Animation Choreography

```swift
struct ParallaxKenBurnsView: View {
    @State private var progress: CGFloat = 0

    let backgroundPan = CGSize(width: 60, height: -40)  // More movement
    let foregroundPan = CGSize(width: 15, height: -10)  // Less movement (parallax!)

    var body: some View {
        ZStack {
            // Background layer - Ken Burns effect
            Image(uiImage: backgroundImage)
                .resizable()
                .scaleEffect(1.0 + (0.3 * progress))
                .offset(
                    x: backgroundPan.width * progress,
                    y: backgroundPan.height * progress
                )

            // Foreground subject - subtle movement or stationary
            Image(uiImage: foregroundImage)
                .resizable()
                .scaleEffect(1.0 + (0.1 * progress))  // Subtle zoom
                .offset(
                    x: foregroundPan.width * progress,
                    y: foregroundPan.height * progress
                )
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 8.0)) {
                progress = 1.0
            }
        }
    }
}
```

---

## Implementation Plan

### Phase 1: Foundation

1. **Photo Loading Pipeline**
   - Use `PHImageManager` to load photos
   - Detect available auxiliary data (depth, mattes)
   - Cache processed layers

2. **Subject Isolation Service**
   ```swift
   class SubjectIsolationService {
       func isolateSubjects(from image: CGImage) async throws -> IsolationResult {
           // VNGenerateForegroundInstanceMaskRequest
       }

       func extractPortraitMatte(from data: Data) throws -> CVPixelBuffer? {
           // AVPortraitEffectsMatte extraction
       }
   }
   ```

3. **Saliency Analysis**
   ```swift
   class SaliencyAnalyzer {
       func findFocalPoints(in image: CGImage) async throws -> [CGRect] {
           // VNGenerateAttentionBasedSaliencyImageRequest
       }
   }
   ```

### Phase 2: Layer Composition

1. **Layer Generator**
   ```swift
   struct PhotoLayers {
       let background: CIImage
       let foreground: CIImage  // With alpha
       let mask: CIImage
       let focalPoints: [CGRect]
   }

   class LayerGenerator {
       func generateLayers(for photo: PHAsset) async throws -> PhotoLayers
   }
   ```

2. **CoreImage Pipeline**
   - Blend with mask filter
   - Optional background blur/effects
   - HDR preservation

### Phase 3: Animation Engine

1. **Ken Burns Calculator**
   ```swift
   struct KenBurnsKeyframes {
       let startScale: CGFloat
       let endScale: CGFloat
       let startOffset: CGSize
       let endOffset: CGSize
       let duration: TimeInterval
   }

   class KenBurnsCalculator {
       func calculateKeyframes(
           imageSize: CGSize,
           containerSize: CGSize,
           focalPoints: [CGRect]
       ) -> KenBurnsKeyframes
   }
   ```

2. **Parallax Animator**
   ```swift
   class ParallaxAnimator {
       func animate(
           background: CALayer,
           foreground: CALayer,
           keyframes: KenBurnsKeyframes,
           parallaxRatio: CGFloat  // 0.3 = foreground moves 30% of background
       )
   }
   ```

### Phase 4: Slideshow Controller

1. **Transition Manager**
   - Cross-dissolve between photos
   - Coordinate timing with Ken Burns
   - Preload next photo's layers

2. **Playback Controls**
   - Play/pause
   - Skip forward/back
   - Adjustable duration

### Phase 5: Polish & Optimization

1. **Performance Optimization**
   - Background processing queue
   - Metal-accelerated compositing
   - Aggressive caching

2. **Visual Enhancements**
   - Subtle shadow under foreground
   - Optional depth-of-field blur on background
   - Smooth easing curves

---

## Code Examples

### Complete Subject Isolation Flow

```swift
import Vision
import CoreImage

class SubjectIsolator {
    private let context = CIContext()

    func isolate(image: CGImage) async throws -> (foreground: CGImage, background: CGImage) {
        // 1. Create and perform Vision request
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        guard let observation = request.results?.first else {
            throw IsolationError.noSubjectsFound
        }

        // 2. Generate mask
        let mask = try observation.createScaledMask(
            forInstances: observation.allInstances,
            from: handler
        )

        // 3. Convert to CIImages
        let ciSource = CIImage(cgImage: image)
        let ciMask = CIImage(cvPixelBuffer: mask)

        // 4. Create foreground (subject with transparency)
        let foregroundFilter = CIFilter(name: "CIBlendWithMask")!
        foregroundFilter.setValue(ciSource, forKey: kCIInputImageKey)
        foregroundFilter.setValue(ciMask, forKey: kCIInputMaskImageKey)
        foregroundFilter.setValue(CIImage.empty(), forKey: kCIInputBackgroundImageKey)

        guard let foregroundCI = foregroundFilter.outputImage,
              let foregroundCG = context.createCGImage(foregroundCI, from: foregroundCI.extent) else {
            throw IsolationError.renderingFailed
        }

        // 5. Create background (with subject removed, optionally filled)
        // For parallax, we might want to in-paint or blur the subject area
        let invertFilter = CIFilter(name: "CIColorInvert")!
        invertFilter.setValue(ciMask, forKey: kCIInputImageKey)
        let invertedMask = invertFilter.outputImage!

        let backgroundFilter = CIFilter(name: "CIBlendWithMask")!
        backgroundFilter.setValue(ciSource, forKey: kCIInputImageKey)
        backgroundFilter.setValue(invertedMask, forKey: kCIInputMaskImageKey)
        backgroundFilter.setValue(ciSource.applyingGaussianBlur(sigma: 20), forKey: kCIInputBackgroundImageKey)

        guard let backgroundCI = backgroundFilter.outputImage,
              let backgroundCG = context.createCGImage(backgroundCI, from: backgroundCI.extent) else {
            throw IsolationError.renderingFailed
        }

        return (foregroundCG, backgroundCG)
    }
}
```

### SwiftUI Parallax Ken Burns View

```swift
import SwiftUI

struct ParallaxSlideshowView: View {
    let backgroundImage: NSImage
    let foregroundImage: NSImage

    @State private var animationProgress: CGFloat = 0

    // Parallax configuration
    let backgroundScale: ClosedRange<CGFloat> = 1.0...1.35
    let foregroundScale: ClosedRange<CGFloat> = 1.0...1.1
    let backgroundOffset = CGSize(width: 80, height: -50)
    let foregroundOffset = CGSize(width: 20, height: -12)  // ~25% of background
    let duration: TimeInterval = 10.0

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background layer - full Ken Burns
                Image(nsImage: backgroundImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .scaleEffect(lerp(backgroundScale, progress: animationProgress))
                    .offset(
                        x: backgroundOffset.width * animationProgress,
                        y: backgroundOffset.height * animationProgress
                    )

                // Foreground layer - subtle parallax
                Image(nsImage: foregroundImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .scaleEffect(lerp(foregroundScale, progress: animationProgress))
                    .offset(
                        x: foregroundOffset.width * animationProgress,
                        y: foregroundOffset.height * animationProgress
                    )
                    .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .onAppear {
            startAnimation()
        }
    }

    private func startAnimation() {
        withAnimation(.easeInOut(duration: duration)) {
            animationProgress = 1.0
        }
    }

    private func lerp(_ range: ClosedRange<CGFloat>, progress: CGFloat) -> CGFloat {
        range.lowerBound + (range.upperBound - range.lowerBound) * progress
    }
}
```

### Saliency-Guided Pan Calculation

```swift
import Vision

class SmartPanCalculator {

    func calculatePanKeyframes(
        for image: CGImage,
        containerSize: CGSize,
        duration: TimeInterval
    ) async throws -> KenBurnsKeyframes {

        // 1. Analyze saliency
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        guard let observation = request.results?.first,
              let salientObject = observation.salientObjects?.first else {
            // No salient region found - use center-based default
            return defaultKeyframes(imageSize: CGSize(width: image.width, height: image.height))
        }

        let imageSize = CGSize(width: image.width, height: image.height)

        // 2. Convert normalized bounding box to image coordinates
        let salientRect = CGRect(
            x: salientObject.boundingBox.origin.x * imageSize.width,
            y: (1 - salientObject.boundingBox.origin.y - salientObject.boundingBox.height) * imageSize.height,
            width: salientObject.boundingBox.width * imageSize.width,
            height: salientObject.boundingBox.height * imageSize.height
        )

        let salientCenter = CGPoint(
            x: salientRect.midX,
            y: salientRect.midY
        )

        // 3. Calculate pan to move toward salient region
        let imageCenter = CGPoint(x: imageSize.width / 2, y: imageSize.height / 2)

        // Start slightly off from salient area, end centered on it
        let startOffset = CGSize(
            width: (imageCenter.x - salientCenter.x) * 0.3,
            height: (imageCenter.y - salientCenter.y) * 0.3
        )

        let endOffset = CGSize(
            width: (salientCenter.x - imageCenter.x) * 0.2,
            height: (salientCenter.y - imageCenter.y) * 0.2
        )

        return KenBurnsKeyframes(
            startScale: 1.0,
            endScale: 1.25,
            startOffset: startOffset,
            endOffset: endOffset,
            duration: duration
        )
    }

    private func defaultKeyframes(imageSize: CGSize) -> KenBurnsKeyframes {
        KenBurnsKeyframes(
            startScale: 1.0,
            endScale: 1.3,
            startOffset: CGSize(width: -30, height: 20),
            endOffset: CGSize(width: 30, height: -20),
            duration: 8.0
        )
    }
}

struct KenBurnsKeyframes {
    let startScale: CGFloat
    let endScale: CGFloat
    let startOffset: CGSize
    let endOffset: CGSize
    let duration: TimeInterval
}
```

---

## Performance Considerations

### Processing Pipeline

1. **Background Processing**
   - Vision requests are resource-intensive
   - Always perform on background queue
   - Use async/await for clean code flow

2. **Caching Strategy**
   ```swift
   class LayerCache {
       private var cache = NSCache<NSString, CachedLayers>()

       func layers(for assetID: String) -> PhotoLayers? {
           cache.object(forKey: assetID as NSString)?.layers
       }

       func store(_ layers: PhotoLayers, for assetID: String) {
           cache.setObject(CachedLayers(layers: layers), forKey: assetID as NSString)
       }
   }
   ```

3. **Preloading**
   - Start processing next 2-3 photos while current one plays
   - Use `PHCachingImageManager` for thumbnails

### Memory Management

- Vision masks can be large (full image resolution)
- Release processed buffers promptly
- Consider lower resolution for real-time preview

### Metal Acceleration

For best performance, use Metal-backed CoreImage:

```swift
let context = CIContext(mtlDevice: MTLCreateSystemDefaultDevice()!)
```

---

## Platform Availability

### Minimum Requirements by Feature

| Feature | iOS | macOS | visionOS |
|---------|-----|-------|----------|
| VNGenerateForegroundInstanceMaskRequest | 17.0 | 14.0 | 1.0 |
| VNInstanceMaskObservation | 17.0 | 14.0 | 1.0 |
| VNGenerateAttentionBasedSaliencyImageRequest | 13.0 | 10.15 | 1.0 |
| AVPortraitEffectsMatte | 12.0 | 10.14 | 1.0 |
| AVSemanticSegmentationMatte | 13.0 | 10.15 | 1.0 |
| AVDepthData | 11.0 | 10.13 | 1.0 |
| Spatial Photos | 17.0 | 14.0 | 1.0 |
| CAKeyframeAnimation | 2.0 | 10.5 | 1.0 |
| CIBlendWithMask | 5.0 | 10.4 | 1.0 |

### Graceful Degradation

For older systems or photos without depth/matte data:
1. Fall back to standard Ken Burns (no parallax)
2. Use saliency for smart panning
3. Skip subject isolation if unavailable

---

## Potential Enhancements

### Future Improvements

1. **3D Subject Float Effect**
   - Use depth data to create subtle Z-axis movement
   - Subject appears to float toward viewer

2. **Multi-Layer Parallax**
   - Separate image into 3+ depth layers
   - Each layer moves at different speeds

3. **Dynamic Focus**
   - Blur shifts between foreground/background
   - Simulates rack focus in cinema

4. **visionOS Spatial Experience**
   - True 3D parallax using spatial photos
   - Subject exists in real depth space

5. **AI-Powered In-Painting**
   - Fill the "hole" behind lifted subjects
   - Creates cleaner background layer

---

## References

### Apple Documentation
- [VNGenerateForegroundInstanceMaskRequest](https://developer.apple.com/documentation/vision/vngenerateforegroundinstancemaskrequest/)
- [Applying visual effects to foreground subjects](https://developer.apple.com/documentation/vision/applying-visual-effects-to-foreground-subjects/)
- [Cropping Images Using Saliency](https://developer.apple.com/documentation/vision/cropping-images-using-saliency/)
- [Capturing photos with depth](https://developer.apple.com/documentation/avfoundation/capturing-photos-with-depth/)
- [Creating spatial photos and videos](https://developer.apple.com/documentation/imageio/creating-spatial-photos-and-videos-with-spatial-metadata/)
- [AVPortraitEffectsMatte](https://developer.apple.com/documentation/avfoundation/avportraiteffectsmatte/)
- [CAKeyframeAnimation](https://developer.apple.com/documentation/quartzcore/cakeyframeanimation/)

### WWDC Sessions
- [Lift subjects from images in your app](https://developer.apple.com/videos/play/wwdc2023/10176/) - WWDC 2023
- [Explore 3D body pose and person segmentation in Vision](https://developer.apple.com/videos/play/wwdc2023/111241/) - WWDC 2023

---

## Summary

Building a Ken Burns parallax slideshow with Apple's subject isolation technology involves:

1. **Subject Isolation**: Use `VNGenerateForegroundInstanceMaskRequest` to separate subjects from backgrounds
2. **Smart Panning**: Use saliency detection to determine focal points for pan/zoom
3. **Layer Composition**: Combine foreground and background using CoreImage filters
4. **Parallax Animation**: Apply different animation parameters to each layer
5. **Performance**: Process in background, cache layers, use Metal acceleration

The result is a cinematic photo viewing experience where subjects appear to float above their backgrounds with beautiful, smooth Ken Burns motion.
