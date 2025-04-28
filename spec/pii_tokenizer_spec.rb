require 'spec_helper'
require 'faraday'

RSpec.describe PiiTokenizer do
  it 'has a version number' do
    expect(PiiTokenizer::VERSION).not_to be nil
  end

  it 'can be configured' do
    described_class.configure do |config|
      config.encryption_service_url = 'https://new-url.com'
      config.batch_size = 10
    end

    expect(described_class.configuration.encryption_service_url).to eq('https://new-url.com')
    expect(described_class.configuration.batch_size).to eq(10)

    # Reset for other tests
    described_class.reset
  end
end
