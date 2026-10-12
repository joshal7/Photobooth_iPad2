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
            let startDate = Calendar.current.date(byAdding: .hour, value: -hours, to: endDate)!
            
            // Predicate: created >= startDate AND mediaSubtype == photoAnimated
            // Note: Some GIFs might not be marked as .photoAnimated by all sources, but our app likely saves them as such
            // or we can check the file extension/UTI if needed. Using .photoAnimated is safer for "Live Photos" vs GIFs differentiation,
            // but standard GIFs are usually .photoAnimated or just images.
            // Let's filter by creation date first, then check resources.
            // Actually, `mediaSubtype` .photoAnimated usually refers to true GIFs or Live Photos? 
            // .photoLive is for Live Photos. .photoAnimated is for GIFs.
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
            // Protect result array
            let lock = NSLock()
            
            // Limit concurrent requests if needed, but for now specific valid assets should be few.
            // assets is a PHFetchResult, we can iterate.
            
            assets.enumerateObjects { asset, _, _ in
                group.enter()
                
                let resourceOptions = PHAssetResourceRequestOptions()
                resourceOptions.isNetworkAccessAllowed = true
                
                // We want the original data (the GIF file)
                let resources = PHAssetResource.assetResources(for: asset)
                if let gifResource = resources.first(where: { $0.uniformTypeIdentifier == "com.compuserve.gif" } ) {
                    
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
                        group.leave()
                    }
                } else {
                    // Fallback: Request Image Data if resource not found directly
                    let imageManager = PHImageManager.default()
                    let options = PHImageRequestOptions()
                    options.isNetworkAccessAllowed = true
                    options.version = .original
                    
                    imageManager.requestImageDataAndOrientation(for: asset, options: options) { data, dataUTI, _, info in
                        defer { group.leave() }
                        
                        guard let data = data, let uti = dataUTI else { return }
                        
                        // Check if it's a GIF
                        if UTType(uti)?.conforms(to: .gif) == true {
                             let filename = "exported_\(UUID().uuidString).gif"
                             let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
                             do {
                                 try data.write(to: tempURL)
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
