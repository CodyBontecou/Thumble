const fs = require('fs');
const path = require('path');
const { withDangerousMod, withXcodeProject } = require('expo/config-plugins');

// ScrawlKit for iOS Debug builds: hold three fingers to record the screen, your voice and
// touches and send them to Scrawl on the Mac. Release builds never import it. Adapted from
// myself.md's plugin for Expo SDK 58, whose scene lifecycle lives in SceneDelegate.swift.
// Pair with `scrawl link --scheme thumble`; unpair with thumble://scrawl?reset=1.
const repositoryURL = 'https://github.com/kitlangton/scrawl';
const revision = 'b5fa0705f6e5724ede414727797b4b6ed274d3d2';
const marker = '// ScrawlKit (with-scrawl)';
const template = 'class SceneDelegate: ExpoAppSceneDelegate {\n  // Extension point for config plugins.\n}';

const sceneDelegate = `${marker}
#if DEBUG
import UIKit
import SwiftUI
import ObjectiveC
import ScrawlKit
#endif

@objc(SceneDelegate)
class SceneDelegate: ExpoAppSceneDelegate {
#if DEBUG
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    // A pairing link that launches a stopped app arrives here rather than in openURLContexts.
    connectionOptions.urlContexts.forEach { _ = Scrawl.handleSetupURL($0.url) }
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    // Move React Native into a window that keeps RN presses working beside Scrawl's observer.
    guard let windowScene = scene as? UIWindowScene, let current = window else { return }
    let touch = ScrawlTouchWindow(windowScene: windowScene)
    touch.rootViewController = current.rootViewController
    current.rootViewController = nil
    current.isHidden = true
    touch.makeKeyAndVisible()
    window = touch
    (UIApplication.shared.delegate as? AppDelegate)?.window = touch
    installScrawl(in: touch)
  }

  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    let others = URLContexts.filter { !Scrawl.handleSetupURL($0.url) }
    if !others.isEmpty { super.scene(scene, openURLContexts: others) }
  }

  // A zero-size SwiftUI child attaches ScrawlKit's window observer to React Native's window.
  @MainActor
  private func installScrawl(in window: UIWindow) {
    guard let parent = window.rootViewController else { return }
    let host = UIHostingController(rootView: Color.clear.scrawl())
    parent.addChild(host)
    host.view.frame = .zero
    host.view.isUserInteractionEnabled = false
    parent.view.addSubview(host.view)
    host.didMove(toParent: parent)
  }
#endif
}

#if DEBUG
// React Native waits for ancestor recognizers to fail. Scrawl's passive observer never
// recognizes, so that dependency blocks RN presses indefinitely (found on myself.md, Oct 20).
private final class ScrawlTouchDelegate: NSObject, UIGestureRecognizerDelegate {
  @MainActor private static let preventionCompatibility: Void = {
    let selector = NSSelectorFromString("canBePreventedByGestureRecognizer:")
    typealias Policy = @convention(c) (UIGestureRecognizer, Selector, UIGestureRecognizer) -> Bool
    for name in ["RCTSurfaceTouchHandler", "RCTTouchHandler"] {
      guard let handler = NSClassFromString(name),
        let method = class_getInstanceMethod(handler, selector) else { continue }
      let original = unsafeBitCast(method_getImplementation(method), to: Policy.self)
      let policy: @convention(block) (UIGestureRecognizer, UIGestureRecognizer) -> Bool = { handler, other in
        if NSStringFromClass(type(of: other)) == "ScrawlKit.TouchObserver" { return false }
        return original(handler, selector, other)
      }
      method_setImplementation(method, imp_implementationWithBlock(policy))
    }
  }()

  @MainActor static func installPreventionCompatibility() {
    _ = preventionCompatibility
  }

  private weak var original: (any UIGestureRecognizerDelegate)?

  init(original: any UIGestureRecognizerDelegate) {
    self.original = original
    super.init()
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
    shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
    if NSStringFromClass(type(of: otherGestureRecognizer)) == "ScrawlKit.TouchObserver" {
      return false
    }
    return original?.gestureRecognizer?(gestureRecognizer,
      shouldRequireFailureOf: otherGestureRecognizer) ?? false
  }

  override func responds(to selector: Selector!) -> Bool {
    super.responds(to: selector) || (original?.responds(to: selector) ?? false)
  }

  override func forwardingTarget(for selector: Selector!) -> Any? {
    original
  }
}

private final class ScrawlTouchWindow: UIWindow {
  private let touchDelegates = NSMapTable<UIGestureRecognizer, ScrawlTouchDelegate>.weakToStrongObjects()

  override func addGestureRecognizer(_ gestureRecognizer: UIGestureRecognizer) {
    if NSStringFromClass(type(of: gestureRecognizer)) == "ScrawlKit.TouchObserver" {
      ScrawlTouchDelegate.installPreventionCompatibility()
      var pending: [UIView] = [self]
      while let view = pending.popLast() {
        installTouchDelegates(in: view)
        pending.append(contentsOf: view.subviews)
      }
    }
    super.addGestureRecognizer(gestureRecognizer)
  }

  private func installTouchDelegates(in view: UIView) {
    for recognizer in view.gestureRecognizers ?? [] {
      let name = NSStringFromClass(type(of: recognizer))
      guard name == "RCTSurfaceTouchHandler" || name == "RCTTouchHandler",
        let original = recognizer.delegate,
        !(original is ScrawlTouchDelegate) else { continue }
      let proxy = ScrawlTouchDelegate(original: original)
      touchDelegates.setObject(proxy, forKey: recognizer)
      recognizer.delegate = proxy
    }
  }

  override func sendEvent(_ event: UIEvent) {
    if event.type == .touches {
      for touch in event.allTouches ?? [] {
        var ancestor = touch.view
        while let view = ancestor {
          installTouchDelegates(in: view)
          ancestor = view.superview
        }
      }
    }
    super.sendEvent(event)
  }
}
#endif
`;

/** @param {import('expo/config').ExpoConfig} config */
module.exports = function withScrawl(config) {
  config = withDangerousMod(config, ['ios', (mod) => {
    const file = path.join(mod.modRequest.platformProjectRoot, mod.modRequest.projectName, 'SceneDelegate.swift');
    const source = fs.readFileSync(file, 'utf8');
    if (source.includes(marker)) return mod;
    if (!source.includes(template) || !source.includes('@objc(SceneDelegate)\n')) {
      throw new Error('Scrawl could not find the Expo SDK 58 SceneDelegate template.');
    }
    const head = source.slice(0, source.indexOf('@objc(SceneDelegate)\n'));
    fs.writeFileSync(file, head + sceneDelegate);
    return mod;
  }]);

  return withXcodeProject(config, (mod) => {
    const project = mod.modResults;
    const objects = project.hash.project.objects;
    const target = project.getFirstTarget();
    const root = project.getFirstProject().firstProject;
    const packages = (objects.XCRemoteSwiftPackageReference ??= {});
    const existing = Object.values(packages).some(
      (value) => typeof value === 'object' && value.repositoryURL?.replaceAll('"', '') === repositoryURL,
    );
    if (!existing) {
      const packageID = project.generateUuid();
      const productID = project.generateUuid();
      const buildID = project.generateUuid();
      packages[packageID] = {
        isa: 'XCRemoteSwiftPackageReference',
        repositoryURL: `"${repositoryURL}"`,
        requirement: { kind: 'revision', revision },
      };
      packages[`${packageID}_comment`] = 'XCRemoteSwiftPackageReference "scrawl"';
      const products = (objects.XCSwiftPackageProductDependency ??= {});
      products[productID] = {
        isa: 'XCSwiftPackageProductDependency',
        package: packageID,
        package_comment: 'XCRemoteSwiftPackageReference "scrawl"',
        productName: 'ScrawlKit',
      };
      products[`${productID}_comment`] = 'ScrawlKit';
      objects.PBXBuildFile[buildID] = { isa: 'PBXBuildFile', productRef: productID, productRef_comment: 'ScrawlKit' };
      objects.PBXBuildFile[`${buildID}_comment`] = 'ScrawlKit in Frameworks';
      (root.packageReferences ??= []).push({ value: packageID, comment: 'XCRemoteSwiftPackageReference "scrawl"' });
      (target.firstTarget.packageProductDependencies ??= []).push({ value: productID, comment: 'ScrawlKit' });
      project.pbxFrameworksBuildPhaseObj(target.uuid).files.push({ value: buildID, comment: 'ScrawlKit in Frameworks' });
    }
    // ScrawlKit needs iOS 18; only Debug raises the app target, Release keeps Expo's target.
    const configs = objects.XCConfigurationList[target.firstTarget.buildConfigurationList].buildConfigurations;
    for (const { value } of configs) {
      const buildConfig = objects.XCBuildConfiguration[value];
      if (buildConfig.name.replaceAll('"', '') === 'Debug') buildConfig.buildSettings.IPHONEOS_DEPLOYMENT_TARGET = '18.0';
    }
    return mod;
  });
};
