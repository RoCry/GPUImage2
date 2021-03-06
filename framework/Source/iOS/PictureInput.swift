import OpenGLES
import UIKit

public enum PictureInputTransformStep {
    case scale(x: CGFloat, y: CGFloat)
    case translation(tx: CGFloat, ty: CGFloat)
    case rotation(angle: CGFloat)
    
    var isTranslation: Bool {
        switch self {
        case .translation: return true
        default: return false
        }
    }
}

public enum PictureInputError: Error, CustomStringConvertible {
    case zeroSizedImageError
    case dataProviderNilError
    case noSuchImageError(imageName: String)
    
    public var errorDescription: String {
        switch self {
        case .zeroSizedImageError:
            return "Tried to pass in a zero-sized image"
        case .dataProviderNilError:
            return "Unable to retrieve image dataProvider"
        case .noSuchImageError(let imageName):
            return "No such image named: \(imageName) in your application bundle"
        }
    }
    
    public var description: String {
        return "<\(type(of: self)): errorDescription = \(self.errorDescription)>"
    }
}

public class PictureInput: ImageSource {
    public let targets = TargetContainer()
    public private(set) var imageFramebuffer: Framebuffer?
    public var framebufferUserInfo: [AnyHashable: Any]?
    public let imageName: String
    var hasProcessedImage: Bool = false
    
    public init(
        image: CGImage,
        imageName: String? = nil,
        smoothlyScaleOutput: Bool = false,
        orientation: ImageOrientation = .portrait) throws {
        self.imageName = imageName ?? "CGImage"

        let widthOfImage = GLint(image.width)
        let heightOfImage = GLint(image.height)
        
        // If passed an empty image reference, CGContextDrawImage will fail in future versions of the SDK.
        guard (widthOfImage > 0) && (heightOfImage > 0) else { throw PictureInputError.zeroSizedImageError }
        
        var widthToUseForTexture = widthOfImage
        var heightToUseForTexture = heightOfImage
        var shouldRedrawUsingCoreGraphics = false
        
        // For now, deal with images larger than the maximum texture size by resizing to be within that limit
        let scaledImageSizeToFitOnGPU = GLSize(sharedImageProcessingContext.sizeThatFitsWithinATextureForSize(Size(width: Float(widthOfImage), height: Float(heightOfImage))))
        if (scaledImageSizeToFitOnGPU.width != widthOfImage) && (scaledImageSizeToFitOnGPU.height != heightOfImage) {
            widthToUseForTexture = scaledImageSizeToFitOnGPU.width
            heightToUseForTexture = scaledImageSizeToFitOnGPU.height
            shouldRedrawUsingCoreGraphics = true
        }
        
        if smoothlyScaleOutput {
            // In order to use mipmaps, you need to provide power-of-two textures, so convert to the next largest power of two and stretch to fill
            let powerClosestToWidth = ceil(log2(Float(widthToUseForTexture)))
            let powerClosestToHeight = ceil(log2(Float(heightToUseForTexture)))
            
            widthToUseForTexture = GLint(round(pow(2.0, powerClosestToWidth)))
            heightToUseForTexture = GLint(round(pow(2.0, powerClosestToHeight)))
            shouldRedrawUsingCoreGraphics = true
        }
        
        var imageData: UnsafeMutablePointer<GLubyte>!
        var dataFromImageDataProvider: CFData!
        var format = GL_BGRA
        
        if !shouldRedrawUsingCoreGraphics {
            /* Check that the memory layout is compatible with GL, as we cannot use glPixelStore to
             * tell GL about the memory layout with GLES.
             */
            if (image.bytesPerRow != image.width * 4) || (image.bitsPerPixel != 32) || (image.bitsPerComponent != 8) {
                shouldRedrawUsingCoreGraphics = true
            } else {
                /* Check that the bitmap pixel format is compatible with GL */
                let bitmapInfo = image.bitmapInfo
                if bitmapInfo.contains(.floatComponents) {
                    /* We don't support float components for use directly in GL */
                    shouldRedrawUsingCoreGraphics = true
                } else {
                    let alphaInfo = CGImageAlphaInfo(rawValue: bitmapInfo.rawValue & CGBitmapInfo.alphaInfoMask.rawValue)
                    if bitmapInfo.contains(.byteOrder32Little) {
                        /* Little endian, for alpha-first we can use this bitmap directly in GL */
                        if (alphaInfo != CGImageAlphaInfo.premultipliedFirst) && (alphaInfo != CGImageAlphaInfo.first) && (alphaInfo != CGImageAlphaInfo.noneSkipFirst) {
                            shouldRedrawUsingCoreGraphics = true
                        }
                    } else if (bitmapInfo.contains(CGBitmapInfo())) || (bitmapInfo.contains(.byteOrder32Big)) {
                        /* Big endian, for alpha-last we can use this bitmap directly in GL */
                        if (alphaInfo != CGImageAlphaInfo.premultipliedLast) && (alphaInfo != CGImageAlphaInfo.last) && (alphaInfo != CGImageAlphaInfo.noneSkipLast) {
                            shouldRedrawUsingCoreGraphics = true
                        } else {
                            /* Can access directly using GL_RGBA pixel format */
                            format = GL_RGBA
                        }
                    }
                }
            }
        }
        
        try sharedImageProcessingContext.runOperationSynchronously {
            if shouldRedrawUsingCoreGraphics {
                // For resized or incompatible image: redraw
                imageData = UnsafeMutablePointer<GLubyte>.allocate(capacity: Int(widthToUseForTexture * heightToUseForTexture) * 4)
                
                let genericRGBColorspace = CGColorSpaceCreateDeviceRGB()
                
                let imageContext = CGContext(data: imageData, width: Int(widthToUseForTexture), height: Int(heightToUseForTexture), bitsPerComponent: 8, bytesPerRow: Int(widthToUseForTexture) * 4, space: genericRGBColorspace, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
                //        CGContextSetBlendMode(imageContext, kCGBlendModeCopy); // From Technical Q&A QA1708: http://developer.apple.com/library/ios/#qa/qa1708/_index.html
                imageContext?.draw(image, in: CGRect(x: 0.0, y: 0.0, width: CGFloat(widthToUseForTexture), height: CGFloat(heightToUseForTexture)))
            } else {
                // Access the raw image bytes directly
                guard let data = image.dataProvider?.data else { throw PictureInputError.dataProviderNilError }
                dataFromImageDataProvider = data
                imageData = UnsafeMutablePointer<GLubyte>(mutating: CFDataGetBytePtr(dataFromImageDataProvider))
            }
            
            // TODO: Alter orientation based on metadata from photo
            self.imageFramebuffer = try Framebuffer(context: sharedImageProcessingContext, orientation: orientation, size: GLSize(width: widthToUseForTexture, height: heightToUseForTexture), textureOnly: true)
            self.imageFramebuffer!.lock()
            
            glBindTexture(GLenum(GL_TEXTURE_2D), self.imageFramebuffer!.texture)
            if smoothlyScaleOutput {
                glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_LINEAR_MIPMAP_LINEAR)
            }
            
            glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GL_RGBA, widthToUseForTexture, heightToUseForTexture, 0, GLenum(format), GLenum(GL_UNSIGNED_BYTE), imageData)
            
            if smoothlyScaleOutput {
                glGenerateMipmap(GLenum(GL_TEXTURE_2D))
            }
            glBindTexture(GLenum(GL_TEXTURE_2D), 0)
        }
        
        if shouldRedrawUsingCoreGraphics {
            imageData.deallocate()
        }
        
    }
    
    public convenience init(image: UIImage, smoothlyScaleOutput: Bool = false, orientation: ImageOrientation? = nil) throws {
        try self.init(image: image.cgImage!, imageName: "UIImage", smoothlyScaleOutput: smoothlyScaleOutput, orientation: orientation ?? image.imageOrientation.gpuOrientation)
    }
    
    public convenience init(imageName: String, smoothlyScaleOutput: Bool = false, orientation: ImageOrientation? = nil) throws {
        guard let image = UIImage(named: imageName) else { throw PictureInputError.noSuchImageError(imageName: imageName) }
        try self.init(image: image.cgImage!, imageName: imageName, smoothlyScaleOutput: smoothlyScaleOutput, orientation: orientation ?? image.imageOrientation.gpuOrientation)
    }
    
    public convenience init(image: UIImage, size: CGSize?, smoothlyScaleOutput: Bool = false, orientation: ImageOrientation? = nil, transforms: [[PictureInputTransformStep]]? = nil) throws {
        var targetOrientation = orientation ?? image.imageOrientation.gpuOrientation
        var cgImage: CGImage = image.cgImage!
        if let targetSize = size {
            autoreleasepool {
                // Get CIImage with orientation
                guard var newImage = CIImage(
                        image: image,
                        options: [
                            .applyOrientationProperty: true,
                            .properties: [
                                kCGImagePropertyOrientation: image.imageOrientation.cgImageOrientation.rawValue
                            ]
                        ]
                ) else { return }
                
                // Scale
                let ratioW = targetSize.width / image.size.width
                let ratioH = targetSize.height / image.size.height
                let fillRatio = max(ratioW, ratioH)
                newImage = newImage.transformed(by: CGAffineTransform(scaleX: fillRatio, y: fillRatio))
                
                var scaleX: CGFloat = 1
                var scaleY: CGFloat = 1
                var translationX: CGFloat = 0
                var translationY: CGFloat = 0
                if let stepGroups = transforms, !stepGroups.isEmpty {
                    var extraTransform = CGAffineTransform.identity
                    for group in stepGroups {
                        var groupTransform = CGAffineTransform.identity
                        for step in group {
                            switch step {
                            case let .scale(x, y):
                                if group.contains(where: { $0.isTranslation }) {
                                    scaleX *= x
                                    scaleY *= y
                                }
                                groupTransform = groupTransform.concatenating(.init(scaleX: x, y: y))
                            case let .translation(tx, ty):
                                translationX += (tx * scaleX * targetSize.width)
                                translationY += (ty * scaleY * targetSize.height)
                                groupTransform = groupTransform.concatenating(.init(translationX: translationX, y: translationY))
                            case let .rotation(angle):
                                groupTransform = groupTransform.concatenating(.init(rotationAngle: angle))
                            }
                        }
                        extraTransform = extraTransform.concatenating(groupTransform)
                    }
                    newImage = newImage.transformed(by: extraTransform)
                }
                
                // Crop and generate image
                let cropRect = CGRect(
                    x: newImage.extent.origin.x - translationX + (newImage.extent.size.width - targetSize.width) / 2,
                    y: newImage.extent.origin.y + translationY + (newImage.extent.size.height - targetSize.height) / 2,
                    width: targetSize.width,
                    height: targetSize.height
                )
                
                let context = CIContext(options: nil)
                cgImage = context.createCGImage(newImage, from: cropRect)!
                targetOrientation = orientation ?? .portrait
            }
        }
        try self.init(image: cgImage, imageName: "UIImage", smoothlyScaleOutput: smoothlyScaleOutput, orientation: targetOrientation)
    }
    
    deinit {
        // debugPrint("Deallocating operation: \(self)")
        
        self.imageFramebuffer?.unlock()
    }
    
    public func processImage(synchronously: Bool = false) {
        self.imageFramebuffer?.userInfo = self.framebufferUserInfo
        
        if synchronously {
            sharedImageProcessingContext.runOperationSynchronously {
                if let framebuffer = self.imageFramebuffer {
                    self.updateTargetsWithFramebuffer(framebuffer)
                    self.hasProcessedImage = true
                }
            }
        } else {
            sharedImageProcessingContext.runOperationAsynchronously {
                if let framebuffer = self.imageFramebuffer {
                    self.updateTargetsWithFramebuffer(framebuffer)
                    self.hasProcessedImage = true
                }
            }
        }
    }
    
    public func transmitPreviousImage(to target: ImageConsumer, atIndex: UInt) {
        // This gets called after the pipline gets adjusted and needs an image it
        // Disabled so we can adjust/prepare the pipline freely without worrying an old framebuffer will get pushed through it
        // If after changing the pipline you need the prior frame buffer to be reprocessed, call processImage() again.
        /*if hasProcessedImage {
            imageFramebuffer.lock()
            target.newFramebufferAvailable(imageFramebuffer, fromSourceIndex:atIndex)
        }*/
    }
}

public extension CGSize {
    func rotatedByOrientation(_ imageOrientation: ImageOrientation) -> CGSize {
        switch imageOrientation {
        case .portrait, .portraitUpsideDown:
            return self
        case .landscapeLeft, .landscapeRight:
            return CGSize(width: height, height: width)
        }
    }
}
