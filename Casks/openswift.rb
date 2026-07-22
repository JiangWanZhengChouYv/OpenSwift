cask "openswift" do
  version "0.1.1"
  sha256 "TO_BE_COMPUTED_AFTER_RELEASE"

  url "https://github.com/JiangWanZhengChouYv/OpenSwift/releases/download/v#{version}/OpenSwift-v#{version}.zip"
  name "OpenSwift"
  desc "macOS app accelerator - control process speed via DYLD injection"
  homepage "https://github.com/JiangWanZhengChouYv/OpenSwift"

  depends_on macos: :ventura

  app "OpenSwift.app"
end
