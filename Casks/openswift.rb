cask "openswift" do
  version "2.2.1"
  sha256 "23b985293e44509cf718654c03ddcf5656df5a5dc45c9dd8a1e7a21a6e3ca30d"

  url "https://github.com/JiangWanZhengChouYv/OpenSwift/releases/download/v#{version}/OpenSwift-v#{version}.zip"
  name "OpenSwift"
  desc "macOS app accelerator - control process speed via DYLD injection"
  homepage "https://github.com/JiangWanZhengChouYv/OpenSwift"

  depends_on macos: :ventura

  app "OpenSwift.app"
end
