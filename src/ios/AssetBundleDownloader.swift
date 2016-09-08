protocol AssetBundleDownloaderDelegate: class {
  func assetBundleDownloaderDidFinish(_ assetBundleDownloader: AssetBundleDownloader)
  func assetBundleDownloader(_ assetBundleDownloader: AssetBundleDownloader, didFailWithError error: Error)
}

final class AssetBundleDownloader: NSObject, URLSessionDelegate, URLSessionTaskDelegate, URLSessionDataDelegate, URLSessionDownloadDelegate, METNetworkReachabilityManagerDelegate {
  fileprivate(set) var configuration: WebAppConfiguration
  fileprivate(set) var assetBundle: AssetBundle
  fileprivate(set) var baseURL: URL

  weak var delegate: AssetBundleDownloaderDelegate?

  /// A private serial queue used to synchronize access
  fileprivate let queue: DispatchQueue

  fileprivate let fileManager = FileManager()

  fileprivate var session: Foundation.URLSession!

  fileprivate var missingAssets: Set<Asset>
  fileprivate var assetsDownloadingByTaskIdentifier = [Int: Asset]()
  fileprivate var resumeDataByAsset = [Asset: Data]()

  fileprivate var retryStrategy: METRetryStrategy
  fileprivate var numberOfRetryAttempts: UInt = 0
  fileprivate var resumeTimer: METTimer!
  fileprivate var networkReachabilityManager: METNetworkReachabilityManager!

  enum Status {
    case suspended
    case running
    case waiting
    case canceling
    case invalid
  }

  fileprivate var status: Status = .suspended

  fileprivate var backgroundTask: UIBackgroundTaskIdentifier = UIBackgroundTaskInvalid

  init(configuration: WebAppConfiguration, assetBundle: AssetBundle, baseURL: URL, missingAssets: Set<Asset>) {
    self.configuration = configuration
    self.assetBundle = assetBundle
    self.baseURL = baseURL
    self.missingAssets = missingAssets

    queue = DispatchQueue(label: "com.meteor.webapp.AssetBundleDownloader", attributes: [])

    retryStrategy = METRetryStrategy()
    retryStrategy.minimumTimeInterval = 0.1
    retryStrategy.numberOfAttemptsAtMinimumTimeInterval = 2
    retryStrategy.baseTimeInterval = 1
    retryStrategy.exponent = 2.2
    retryStrategy.randomizationFactor = 0.5

    super.init()

    let sessionConfiguration = URLSessionConfiguration.default
    sessionConfiguration.httpMaximumConnectionsPerHost = 6

    // Disable the protocol-level local cache, because we make sure to only
    // download changed files, so there is no need to waste additional storage
    sessionConfiguration.urlCache = nil
    sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData

    let operationQueue = OperationQueue()
    operationQueue.maxConcurrentOperationCount = 1
    operationQueue.underlyingQueue = queue

    session = Foundation.URLSession(configuration: sessionConfiguration, delegate: self, delegateQueue: operationQueue)

    resumeTimer = METTimer(queue: queue) { [weak self] in
      self?.resume()
    }

    networkReachabilityManager = METNetworkReachabilityManager(hostName: baseURL.host!)
    networkReachabilityManager.delegate = self
    networkReachabilityManager.delegateQueue = queue
    networkReachabilityManager.startMonitoring()

    NotificationCenter.default.addObserver(self, selector: #selector(AssetBundleDownloader.applicationWillEnterForeground), name: NSNotification.Name.UIApplicationWillEnterForeground, object: nil)
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  func resume() {
    queue.async {
      if self.backgroundTask == UIBackgroundTaskInvalid {
        NSLog("Start downloading assets from bundle with version: \(self.assetBundle.version)")

        CDVTimer.start("assetBundleDownload")

        let application = UIApplication.shared
        self.backgroundTask = application.beginBackgroundTask(withName: "AssetBundleDownload") {
          // Expiration handler, usually invoked 180 seconds after the app goes
          // into the background
          NSLog("AssetBundleDownload task expired, app is suspending")
          self.status = .suspended
          self.endBackgroundTask()
        }
      }

      self.status = .running

      let assetsDownloading = Set(self.assetsDownloadingByTaskIdentifier.values)

      for asset in self.missingAssets {
        if assetsDownloading.contains(asset) { continue }

        let task: URLSessionTask

        // If we have previously stored resume data, use that to recreate the
        // task
        if let resumeData = self.resumeDataByAsset.removeValue(forKey: asset) {
          task = self.session.downloadTask(withResumeData: resumeData)
        } else {
          guard let URL = self.downloadURLForAsset(asset) else {
            self.cancelAndFailWithReason("Invalid URL for asset: \(asset)")
            return
          }

          task = self.session.dataTask(with: URL)
        }

        self.assetsDownloadingByTaskIdentifier[task.taskIdentifier] = asset
        task.resume()
      }
    }
  }

  fileprivate func resumeLater() {
    if status == .running {
      let retryInterval = retryStrategy.retryIntervalForNumber(ofAttempts: numberOfRetryAttempts)
      NSLog("Will retry resuming downloads after %f seconds", retryInterval);
      resumeTimer.start(withTimeInterval: retryInterval)
      numberOfRetryAttempts += 1
      status = .waiting
    }
  }

  fileprivate func downloadURLForAsset(_ asset: Asset) -> URL? {
    var URLPath = asset.URLPath

    // Remove leading / from URL path because the path should be relative to the base URL
    if URLPath.hasPrefix("/") {
      URLPath = String(describing: asset.URLPath.utf16.dropFirst())
    }

    guard var URLComponents = URLComponents(string: URLPath) else {
      return nil
    }

    // To avoid inadvertently downloading the default index page when an asset
    // is not found, we add meteor_dont_serve_index=true to the URL unless we
    // are actually downloading the index page.
    if asset.filePath != "index.html" {
      let queryItem = URLQueryItem(name: "meteor_dont_serve_index", value: "true")
      if var queryItems = URLComponents.queryItems {
        queryItems.append(queryItem)
        URLComponents.queryItems = queryItems
      } else {
        URLComponents.queryItems = [queryItem]
      }
    }

    return URLComponents.url(relativeTo: baseURL)
  }

  fileprivate func endBackgroundTask() {
    let application = UIApplication.shared
    application.endBackgroundTask(self.backgroundTask)
    self.backgroundTask = UIBackgroundTaskInvalid;

    CDVTimer.stop("assetBundleDownload")
  }

  func cancel() {
    queue.sync {
      self._cancel()
    }
  }

  fileprivate func _cancel() {
    if self.status != .canceling || self.status == .invalid {
      self.status = .canceling
      self.session.invalidateAndCancel()
      self.endBackgroundTask()
    }
  }

  fileprivate func cancelAndFailWithReason(_ reason: String, underlyingError: Error? = nil) {
    let error = WebAppError.downloadFailure(reason: reason, underlyingError: underlyingError)
    cancelAndFailWithError(error)
  }

  fileprivate func cancelAndFailWithError(_ error: Error) {
    _cancel()
    delegate?.assetBundleDownloader(self, didFailWithError: error)
  }

  fileprivate func didFinish() {
    session.finishTasksAndInvalidate()
    delegate?.assetBundleDownloaderDidFinish(self)
    endBackgroundTask()
  }

  // MARK: Application State Notifications

  func applicationWillEnterForeground() {
    if status == .suspended {
      resume()
    }
  }

  // MARK: METNetworkReachabilityManagerDelegate

  func networkReachabilityManager(_ reachabilityManager: METNetworkReachabilityManager, didDetectReachabilityStatusChange reachabilityStatus: METNetworkReachabilityStatus) {

    if reachabilityStatus == .reachable && status == .waiting {
      resume()
    }
  }

  // MARK: URLSessionDelegate

  func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
    status = .invalid
  }

  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
  }

  // MARK: URLSessionTaskDelegate

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if let error = error {
      if let asset = assetsDownloadingByTaskIdentifier.removeValue(forKey: task.taskIdentifier) {
        if task is URLSessionDownloadTask && status != .canceling {
          NSLog("Download of asset: \(asset) did fail with error: \(error)")

          // If there is resume data, we store it and use it to recreate the task later
          if let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            resumeDataByAsset[asset] = resumeData
          }
          resumeLater()
        }
      }
    }
  }

  // MARK: URLSessionDataDelegate

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
    if status == .canceling { return }

    guard let response = response as? HTTPURLResponse else { return }

    if let asset = assetsDownloadingByTaskIdentifier[dataTask.taskIdentifier] {
      do {
        try verifyResponse(response, forAsset: asset)
        completionHandler(.becomeDownload)
      } catch {
        completionHandler(.cancel)
        self.cancelAndFailWithError(error)
      }
    }
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didBecome downloadTask: URLSessionDownloadTask) {
    if let asset = assetsDownloadingByTaskIdentifier.removeValue(forKey: dataTask.taskIdentifier) {
      assetsDownloadingByTaskIdentifier[downloadTask.taskIdentifier] = asset
    }
  }

  @available(iOS 9.0, *)
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didBecome streamTask: URLSessionStreamTask) {
    if let asset = assetsDownloadingByTaskIdentifier.removeValue(forKey: dataTask.taskIdentifier) {
      assetsDownloadingByTaskIdentifier[streamTask.taskIdentifier] = asset
    }
  }

  // MARK: URLSessionDownloadDelegate

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didResumeAtOffset fileOffset: Int64, expectedTotalBytes: Int64) {
    if status == .canceling { return }

    guard let response = downloadTask.response as? HTTPURLResponse else { return }

    if let asset = assetsDownloadingByTaskIdentifier[downloadTask.taskIdentifier] {
      do {
        try verifyResponse(response, forAsset: asset)
      } catch {
        self.cancelAndFailWithError(error)
      }
    }
  }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    if let asset = assetsDownloadingByTaskIdentifier.removeValue(forKey: downloadTask.taskIdentifier) {
      if status == .canceling { return }

      // We don't have a hash for the index page, so we have to parse the runtime config
      // and compare autoupdateVersionCordova to the version in the manifest to verify
      // if we downloaded the expected version
      if asset.filePath == "index.html" {
        do {
          let runtimeConfig = try loadRuntimeConfigFromIndexFileAtURL(location)
          try verifyRuntimeConfig(runtimeConfig)
        } catch {
          self.cancelAndFailWithError(error)
          return
        }
      }

      do {
        try fileManager.moveItem(at: location, to: asset.fileURL as URL)
      } catch {
        self.cancelAndFailWithReason("Could not move downloaded asset", underlyingError: error)
        return
      }

      missingAssets.remove(asset)

      if missingAssets.isEmpty {
        didFinish()
      }
    }
  }

  fileprivate func verifyResponse(_ response: HTTPURLResponse, forAsset asset: Asset) throws {
    // A response with a non-success status code should not be considered a succesful download
    if !response.isSuccessful {
      throw WebAppError.downloadFailure(reason: "Non-success status code \(response.statusCode) for asset: \(asset)", underlyingError: nil)
      // If we have a hash for the asset, and the ETag header also specifies
      // a hash, we compare these to verify if we received the expected asset version
    } else if let expectedHash = asset.hash,
      let ETag = response.allHeaderFields["ETag"] as? String,
      let actualHash = SHA1HashFromETag(ETag)
      , actualHash != expectedHash {
        throw WebAppError.downloadFailure(reason: "Hash mismatch for asset: \(asset)", underlyingError: nil)
    }
  }

  fileprivate func verifyRuntimeConfig(_ runtimeConfig: AssetBundle.RuntimeConfig) throws {
    let expectedVersion = assetBundle.version
    if let actualVersion = runtimeConfig.autoupdateVersionCordova
      , expectedVersion != actualVersion {
        throw WebAppError.downloadFailure(reason: "Version mismatch for index page, expected: \(expectedVersion), actual: \(actualVersion)", underlyingError: nil)
    }

    guard let rootURL = runtimeConfig.rootURL else {
      throw WebAppError.unsuitableAssetBundle(reason: "Could not find ROOT_URL in downloaded asset bundle", underlyingError: nil)
    }

    if configuration.rootURL?.host != "localhost" && rootURL.host == "localhost" {
      throw WebAppError.unsuitableAssetBundle(reason: "ROOT_URL in downloaded asset bundle would change current ROOT_URL to localhost. Make sure ROOT_URL has been configured correctly on the server.", underlyingError: nil)
    }

    guard let appId = runtimeConfig.appId else {
      throw WebAppError.unsuitableAssetBundle(reason: "Could not find appId in downloaded asset bundle", underlyingError: nil)
    }

    if appId != configuration.appId {
      throw WebAppError.unsuitableAssetBundle(reason: "appId in downloaded asset bundle does not match current appId. Make sure the server at \(rootURL) is serving the right app.", underlyingError: nil)
    }
  }
}
