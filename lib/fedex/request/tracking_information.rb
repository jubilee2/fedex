require 'fedex/request/base'
require 'fedex/tracking_information'

module Fedex
  module Request
    class TrackingInformation < BaseV20

      attr_reader :package_type, :package_id

      def initialize(credentials, options={})
        requires!(options, :package_type, :package_id) unless options.has_key?(:tracking_number)

        @package_id   = options[:package_id]   || options.delete(:tracking_number)
        @package_type = options[:package_type] || "TRACKING_NUMBER_OR_DOORTAG"
        @credentials  = credentials

        # Optional
        @include_detailed_scans = options[:include_detailed_scans] || true
        @uuid                   = options[:uuid]
        @paging_token           = options[:paging_token]

        unless package_type_valid?
          raise "Unknown package type '#{package_type}'"
        end
      end

      def process_request
        api_response = self.class.post(api_url, :body => build_xml)
        puts api_response if @debug == true
        response = parse_response(api_response)

        if success?(response)
          track_reply = response[:envelope][:body][:track_reply][:completed_track_details]
          options = track_reply[:track_details]

          if !success_tracking?(options)
            error_message = if options
              options[:notification][:message]
            end rescue $1
            raise RateError, error_message
          end

          if track_reply[:duplicate_waybill].downcase == 'true'
            shipments = []
            [options].flatten.map do |details|
              options = {:tracking_number => @package_id, :uuid => details[:tracking_number_unique_identifier]}
              shipments << Request::TrackingInformation.new(@credentials, options).process_request
            end
            shipments.flatten
          else
            [options].flatten.map do |details|
              Fedex::TrackingInformation.new(details)
            end
          end
        else
          track_reply = response[:envelope] && response[:envelope][:body] && response[:envelope][:body][:track_reply]
          error_message = if track_reply
            track_reply[:notifications][:message]
          else
            "#{api_response["Fault"]["detail"]["fault"]["reason"]}\n--#{api_response["Fault"]["detail"]["fault"]["details"]["ValidationFailureDetail"]["message"].join("\n--")}"
          end rescue $1
          raise RateError, error_message
        end
      end

      private

      # Build xml Fedex Web Service request
      def build_xml
        builder = Nokogiri::XML::Builder.new do |xml|
          xml.Envelope(:xmlns => "http://fedex.com/ws/track/v#{service[:version]}"){
            xml.parent.namespace = xml.parent.add_namespace_definition("soapenv", "http://schemas.xmlsoap.org/soap/envelope/")
            xml['soapenv'].Body {
              xml.TrackRequest {
                add_web_authentication_detail(xml)
                add_client_detail(xml)
                add_version(xml)
                xml.SelectionDetails {
                  add_package_identifier(xml)
                  xml.TrackingNumberUniqueIdentifier @uuid         if @uuid
                  if @paging_token
                    xml.PagingDetail {
                      xml.PagingToken @paging_token
                    }
                  end
                }
                xml.ProcessingOptions "INCLUDE_DETAILED_SCANS"     if @include_detailed_scans
              }
            }
          }
        end
        builder.doc.root.to_xml
      end

      def service
        { :id => 'trck', :version => Fedex::TRACK_API_VERSION }
      end

      def add_package_identifier(xml)
        xml.PackageIdentifier{
          xml.Type  package_type
          xml.Value package_id
        }
      end

      # Successful request
      def success?(response)
        response[:envelope] && response[:envelope][:body] && response[:envelope][:body][:track_reply] &&
          %w{SUCCESS WARNING NOTE}.include?(response[:envelope][:body][:track_reply][:highest_severity])
      end

      # Successful teacking number
      def success_tracking?(data)
        data && data[:notification] &&
          %w{SUCCESS WARNING NOTE}.include?(data[:notification][:severity])
      end

      def package_type_valid?
        Fedex::TrackingInformation::PACKAGE_IDENTIFIER_TYPES.include? package_type
      end

    end
  end
end
