import Foundation
import Photos
import UIKit

enum GIFRetrievalError: Error {
    case photoLibraryAccessDenied
    case fetchFailed
    case dataUnavailable
    case fileWriteFailed
}

final class GIFRetrievalService: Sendable {
    
    /// Fetches GIFs created within the last N hours and returns their local file URLs.
    /// - Parameter hours: The window of time in hours.
    /// - Returns: A list of temporary file URLs for the fetched GIFs.
    nonisolated static func fetchRecentGIFs(hours: Int) async throws -> [URL] {
        // 1. Check Permissions
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw GIFRetrievalError.photoLibraryAccessDenied
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            // 2. Setup Fetch Options
            let fetchOptions = PHFetchOptions()
            let endDate = Date()
            let startDate = Calendar.current.date(byAdding: .hour, value: -hours, to: endDate)
                ?? endDate.addingTimeInterval(-Double(hours) * 3600.0)
            
            fetchOptions.predicate = NSPredicate(format: "creationDate >= %@", startDate as NSDate)
            fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            
            let assets = PHAsset.fetchAssets(with: .image, options: fetchOptions)
            
            print("Found \(assets.count) assets in the last \(hours) hours. Scanning for GIFs...")
            
            if assets.count == 0 {
                continuation.resume(returning: [])
                return
            }
            
            // 3. Extract Data & Save to Temp
            var resultURLs: [URL] = []
            let group = DispatchGroup()
            let lock = NSLock()
            
            assets.enumerateObjects { asset, _, _ in
                let resources = PHAssetResource.assetResources(for: asset)
                let gifResource = resources.first { resource in
                    resource.uniformTypeIdentifier == "com.compuserve.gif"
                        || UTType(resource.uniformTypeIdentifier)?.conforms(to: .gif) == true
                        || resource.originalFilename.lowercased().hasSuffix(".gif")
                }
                
                // If the asset has known non-GIF resources and is not marked as an animated image,
                // skip loading its full image data into memory.
                if gifResource == nil && !resources.isEmpty && asset.playbackStyle != .imageAnimated {
                    return
                }
                
                group.enter()
                var hasLeftGroup = false
                let leaveGroupOnce = {
                    lock.lock()
                    let shouldLeave = !hasLeftGroup
                    hasLeftGroup = true
                    lock.unlock()
                    if shouldLeave {
                        group.leave()
                    }
                }
                
                if let gifResource = gifResource {
                    let resourceOptions = PHAssetResourceRequestOptions()
                    resourceOptions.isNetworkAccessAllowed = true
                    
                    let filename = gifResource.originalFilename
                    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "_" + filename)
                    
                    PHAssetResourceManager.default().writeData(for: gifResource, toFile: tempURL, options: resourceOptions) { error in
                        if let error = error {
                            print("Failed to write resource for asset \(asset.localIdentifier): \(error)")
                        } else {
                            lock.lock()
                            resultURLs.append(tempURL)
                            lock.unlock()
                        }
                        leaveGroupOnce()
                    }
                } else {
                    // Fallback: Request Image Data only when resources were unavailable or asset is animated
                    let imageManager = PHImageManager.default()
                    let options = PHImageRequestOptions()
                    options.isNetworkAccessAllowed = true
                    options.version = .original
                    
                    imageManager.requestImageDataAndOrientation(for: asset, options: options) { data, dataUTI, _, _ in
                        defer { leaveGroupOnce() }
                        
                        guard let data = data, let uti = dataUTI else { return }
                        
                        if UTType(uti)?.conforms(to: .gif) == true {
                            let filename = "exported_\(UUID().uuidString).gif"
                            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
                            do {
                                try data.write(to: tempURL, options: .atomic)
                                lock.lock()
                                resultURLs.append(tempURL)
                                lock.unlock()
                            } catch {
                                print("Failed to write data: \(error)")
                            }
                        }
                    }
                }
            }
            
            group.notify(queue: .global()) {
                continuation.resume(returning: resultURLs)
            }
        }
    }
}
