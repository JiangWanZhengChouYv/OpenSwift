cask "openswift" do
  version "2.0.0"
  sha256 "2a5ba12977838b104f5c54b37fe78f270d11fab7261fd37be6ea1cfed8a455db"

  url "https://github.com/JiangWanZhengChouYv/OpenSwift/releases/download/v#{version}/OpenSwift-v#{version}.zip"
  name "OpenSwift"
  desc "macOS app accelerator - control process speed via DYLD injection"
  homepage "https://github.com/JiangWanZhengChouYv/OpenSwift"

  depends_on macos: :ventura

  app "OpenSwift.app"
end
