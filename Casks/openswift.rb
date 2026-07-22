cask "openswift" do
  version "0.1.1"
  sha256 "4898ed2f87027946acdc3decea74acf822950e30c051db0c3e8ba622b05bc341"

  url "https://github.com/JiangWanZhengChouYv/OpenSwift/releases/download/v#{version}/OpenSwift-v#{version}.zip"
  name "OpenSwift"
  desc "macOS app accelerator - control process speed via DYLD injection"
  homepage "https://github.com/JiangWanZhengChouYv/OpenSwift"

  depends_on macos: :ventura

  app "OpenSwift.app"
end
