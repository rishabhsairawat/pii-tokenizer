require "spec_helper"
require "faraday"

RSpec.describe PiiTokenizer do
  it "has a version number" do
    expect(PiiTokenizer::VERSION).not_to be nil
  end

  it "can be configured" do
    PiiTokenizer.configure do |config|
      config.encryption_service_url = "https://new-url.com"
      config.batch_size = 10
    end

    expect(PiiTokenizer.configuration.encryption_service_url).to eq("https://new-url.com")
    expect(PiiTokenizer.configuration.batch_size).to eq(10)

    # Reset for other tests
    PiiTokenizer.reset
  end
end 