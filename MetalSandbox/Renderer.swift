//
//  Renderer.swift
//  MetalSandbox
//
//  Created by John Coates on 9/27/16.
//  Copyright © 2016 John Coates. All rights reserved.
//

import Foundation
import Metal
import MetalKit
import AVFoundation
import CoreVideo
import simd

struct Vertex {
    var position: float4
    var textureCoordinates: float2
}

@objc class Renderer: NSObject, MTKViewDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    
    weak var view: MTKView!
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let renderPipelineState: MTLRenderPipelineState
    
    var vertices = [Vertex]()
    var textureCoordinates = [float2]()
    
    var vertexBuffer: MTLBuffer
    init?(metalView: MTKView) {
        view = metalView
        view.clearColor = MTLClearColorMake(1, 1, 1, 1)
        view.colorPixelFormat = .bgra8Unorm
        
        if let defaultDevice = MTLCreateSystemDefaultDevice() {
            device = defaultDevice
        } else {
            print("Metal is not supported")
            return nil
        }
        
        // Create the command queue to submit work to the GPU
        commandQueue = device.makeCommandQueue()
        
        do {
            renderPipelineState = try Renderer.buildRenderPipeline(device: device,
                                                                   view: metalView)
        } catch {
            print("Unable to compile render pipeline state")
            return nil
        }
        
        // quad
        vertices.append(Vertex(position: float4(-1, -1, 0, 1),
                               textureCoordinates: float2(0,0)))
        vertices.append(Vertex(position: float4(1, -1, 0, 1),
                               textureCoordinates: float2(1,0)))
        vertices.append(Vertex(position: float4(-1, 1, 0, 1),
                               textureCoordinates: float2(0,1)))
        vertices.append(Vertex(position: float4(1, -1, 0, 1),
                               textureCoordinates: float2(1,0)))
        vertices.append(Vertex(position: float4(-1, 1, 0, 1),
                               textureCoordinates: float2(0,1)))
        vertices.append(Vertex(position: float4(1, 1, 0, 1),
                               textureCoordinates: float2(1,1)))
        
        vertexBuffer = device.makeBuffer(bytes: vertices,
                                             length: MemoryLayout<Vertex>.stride * vertices.count,
                                             options: [])
        
        super.init()
        setUpVideoQuadTexture()
        view.delegate = self
        view.device = device
    }
    
    class func buildRenderPipeline(device: MTLDevice, view: MTKView) throws -> MTLRenderPipelineState {
        // The default library contains all of the shader functions that were compiled into our app bundle
        let library = device.newDefaultLibrary()!
        
        // Retrieve the functions that will comprise our pipeline
        let vertexFunction = library.makeFunction(name: "vertexPassthrough")
        let fragmentFunction = library.makeFunction(name: "fragmentPassthrough")
        
        // A render pipeline descriptor describes the configuration of our programmable pipeline
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "Render Pipeline"
        pipelineDescriptor.sampleCount = view.sampleCount
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        pipelineDescriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        
        return try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }
    
    // MARK: - Render
    
    func render(_ view: MTKView) {        
        // Our command buffer is a container for the work we want to perform with the GPU.
        let commandBuffer = commandQueue.makeCommandBuffer()
        
        // Ask the view for a configured render pass descriptor. It will have a loadAction of
        // MTLLoadActionClear and have the clear color of the drawable set to our desired clear color.
        guard let currentDrawable = view.currentDrawable else {
            fatalError("no drawable!")
        }
//        let renderPassDescriptor = view.currentRenderPassDescriptor
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(1, 1, 1, 1)
        renderPassDescriptor.colorAttachments[0].texture = currentDrawable.texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .dontCare
        
        // Create a render encoder to clear the screen and draw our objects
        let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
        
        renderTextureQuad(renderEncoder: renderEncoder, view: view, identifier: "video texture")
       
        // We are finished with this render command encoder, so end it.
        renderEncoder.endEncoding()
        
        // Tell the system to present the cleared drawable to the screen.
        commandBuffer.present(currentDrawable)
        
        // Now that we're done issuing commands, we commit our buffer so the GPU can get to work.
        commandBuffer.commit()
    }
    
    // MARK: - Video
    
    var session: AVCaptureSession!
    var textureCache: CVMetalTextureCache?
    var texture: MTLTexture?
    var sampler: MTLSamplerState!
    func setUpVideoQuadTexture() {
        var cacheAttributes = [NSString : NSNumber]()
        cacheAttributes[kCVMetalTextureCacheMaximumTextureAgeKey as NSString] = NSNumber(value: 2)
        
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault,
                                        cacheAttributes as NSDictionary,
                                        device, nil, &textureCache) == kCVReturnSuccess else {
            fatalError("Couldn't create a texture cache")
        }
        CVMetalTextureCacheFlush(textureCache!, 0)
        
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.label = "video texture sampler"
        sampler = device.makeSamplerState(descriptor: samplerDescriptor)
        guard sampler != nil else {
            fatalError("Couldn't create a texture sampler")
        }
        
        session = AVCaptureSession()
        session.beginConfiguration()
        
        session.sessionPreset = AVCaptureSessionPresetLow
        let camera = AVCaptureDevice.defaultDevice(withMediaType: AVMediaTypeVideo)
        do {
            let input = try AVCaptureDeviceInput(device: camera)
            session.addInput(input)
        } catch {
            print("Couldn't instantiate device input")
            return
        }
        
        let dataOutput = AVCaptureVideoDataOutput()
        dataOutput.alwaysDiscardsLateVideoFrames = true
        
        // set the color space
        let pixelFormat = kCVPixelFormatType_32BGRA
        let pixelFormatKey = kCVPixelBufferPixelFormatTypeKey as NSString
        let metalCompatibilityKey = kCVPixelBufferMetalCompatibilityKey as NSString
        
        dataOutput.videoSettings = [
            pixelFormatKey: NSNumber(value: pixelFormat),
             metalCompatibilityKey: NSNumber(value: true)
        ]
        
        // Set dispatch to be on the main thread to create the texture in memory
        // and allow Metal to use it for rendering
        dataOutput.setSampleBufferDelegate(self, queue: DispatchQueue.main)
        
        session.addOutput(dataOutput)
        session.commitConfiguration()
        session.startRunning()
    }
    
    // MARK: - Video Delegate
    
    func captureOutput(_ captureOutput: AVCaptureOutput!, didOutputSampleBuffer sampleBuffer: CMSampleBuffer!, from connection: AVCaptureConnection!) {
        guard let textureCache = textureCache else {
            print("Missing texture cache!")
            return
        }
        
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            print("Couldn't get image buffer")
            return
        }
        
        var optionalTextureRef: CVMetalTexture? = nil
        
        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        
        let returnValue = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                                    textureCache,
                                                                    imageBuffer,
                                                                    nil,
                                                                    .bgra8Unorm,
                                                                    width, height, 0,
                                                                    &optionalTextureRef)
        if returnValue != kCVReturnSuccess {
            let dataSize = CVPixelBufferGetDataSize(imageBuffer)
            let planes = CVPixelBufferGetPlaneCount(imageBuffer)
            
            print("device: \(device.name)")
            print("width: \(width), height: \(height)")
            print("buffer size: \(dataSize)")
            print("planes: \(planes)")
            print("texture cache: \(textureCache)")
            #if os(macOS)
                let type = UTCreateStringForOSType(CVPixelBufferGetPixelFormatType(imageBuffer)).takeRetainedValue() as String
                print("buffer pixel format: \(type)")
            #endif
            
            print("Error, couldn't create texture from image, error: \(returnValue), \(optionalTextureRef)")
            return
        }
        
        guard let textureRef = optionalTextureRef else {
            print("Nil texture reference returned")
            return
        }
        
        guard let texture = CVMetalTextureGetTexture(textureRef) else {
            print("Error, Couldn't get texture")
            return
        }
        self.texture = texture
        
    }
    
    func renderTextureQuad(renderEncoder: MTLRenderCommandEncoder, view: MTKView, identifier: String) {
        guard let texture = texture else {
            return
        }
        renderEncoder.pushDebugGroup(identifier)
        // Set the pipeline state so the GPU knows which vertex and fragment function to invoke.
        renderEncoder.setRenderPipelineState(renderPipelineState)
        renderEncoder.setFrontFacing(.counterClockwise)
        
        // Bind the buffer containing the array of vertex structures so we can
        // read it in our vertex shader.
        renderEncoder.setVertexBuffer(vertexBuffer, offset:0, at:0)
        renderEncoder.setFragmentTexture(texture, at: 0)
        renderEncoder.setFragmentSamplerState(sampler, at: 0)
        renderEncoder.drawPrimitives(type: .triangle,
                                     vertexStart: 0,
                                     vertexCount: 6,
                                     instanceCount: 1)
        renderEncoder.popDebugGroup()
    }
    
    // MARK: - Metal View Delegate
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // respond to resize
    }
    
    @objc(drawInMTKView:)
    func draw(in metalView: MTKView) {
        render(metalView)
    }
}
