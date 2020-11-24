require "payuindia/version"
require 'payuindia/action_view_helper'
ActionView::Base.send(:include, PayuIndia::ActionViewHelper)

module PayuIndia
  mattr_accessor :test_url
  mattr_accessor :production_url

  self.test_url = 'https://test.payu.in/_payment.php'
  self.production_url = 'https://secure.payu.in/_payment.php'

  def self.service_url
    defined?(Rails) && Rails.env == 'production' ? self.production_url : self.test_url
  end

  def self.notification(post, options = {})
    Notification.new(post, options)
  end

  def self.return(post, options = {})
    Return.new(post, options)
  end

  def self.checksum(merchant_id, secret_key, payload_items )
    Digest::SHA512.hexdigest([merchant_id, *payload_items, secret_key].join("|"))
  end

  class Helper

    CHECKSUM_FIELDS = [ :txnid, :amount, :productinfo, :firstname, :email, :udf1, :udf2, :udf3, :udf4,
                        :udf5, :udf6, :udf7, :udf8, :udf9, :udf10 ]

    def initialize(key, salt, options = {})
      @key, @salt, @options = key, salt, options
    end

    def form_fields
      sanitize_fields
      @options.merge(:hash => generate_checksum)
    end

    def generate_checksum
      checksum_payload_items = CHECKSUM_FIELDS.map { |field| @options[field] }
      PayuIndia.checksum(@key, @salt, checksum_payload_items )
    end

    def sanitize_fields
      [:address1, :address2, :city, :state, :country, :productinfo, :email, :phone].each do |field|
        @options[field].gsub!(/[^a-zA-Z0-9\-_@\/\s.]/, '') if @options[field]
      end
    end

  end

  class Notification
    def initialize(post, options = {})
      @key = options[:key]
      @salt = options[:salt]
      @params = options[:params]
    end

    def complete?
      status == "Completed"
    end

    def params
      @params
    end

    def status
      @status ||= if checksum_ok?
        if transaction_id.blank?
          'Invalid'
        else
          case transaction_status.downcase
          when 'success' then 'Completed'
          when 'failure' then 'Failed'
          when 'pending' then 'Pending'
          end
        end
      else
        'Tampered'
      end
    end

    def invoice_ok?( order_id )
      order_id.to_s == invoice.to_s
    end

    # Order amount should be equal to gross - discount
    def amount_ok?( order_amount, order_discount = BigDecimal.new( '0.0' ) )
      BigDecimal.new( gross ) == order_amount && BigDecimal.new( discount.to_s ) == order_discount
    end

    # Status of transaction return from the PayU. List of possible values:
    # <tt>SUCCESS</tt>::
    # <tt>PENDING</tt>::
    # <tt>FAILURE</tt>::
    def transaction_status
      params['status']
    end

    # ID of this transaction (PayU.in number)
    def transaction_id
      params['mihpayid']
    end

    # Mode of Payment
    #
    # 'CC' for credit-card
    # 'NB' for net-banking
    # 'CD' for cheque or DD
    # 'CO' for Cash Pickup
    def type
      params['mode']
    end

    # What currency have we been dealing with
    def currency
      'INR'
    end

    # This is the invoice which you passed to PayU.in
    def invoice
      params['txnid']
    end

    # Merchant Id provided by the PayU.in
    def account
      params['key']
    end

    # original amount send by merchant
    def gross
      params['amount']
    end

    # This is discount given to user - based on promotion set by merchants.
    def discount
      params['discount']
    end

    # Description offer for what PayU given the offer to user - based on promotion set by merchants.
    def offer_description
      params['offer']
    end

    # Information about the product as send by merchant
    def product_info
      params['productinfo']
    end

    # Email of the customer
    def customer_email
      params['email']
    end

    # Phone of the customer
    def customer_phone
      params['phone']
    end

    # Firstname of the customer
    def customer_first_name
      params['firstname']
    end

    # Lastname of the customer
    def customer_last_name
      params['lastname']
    end

    def additional_charges
      params['additionalCharges']
    end

    # Full address of the customer
    def customer_address
      { :address1 => params['address1'], :address2 => params['address2'],
        :city => params['city'], :state => params['state'],
        :country => params['country'], :zipcode => params['zipcode'] }
    end

    def user_defined
      @user_defined ||= 10.times.map { |i| params["udf#{i + 1}"] }
    end

    def checksum
      params['hash']
    end

    def message
      @message || "#{params['error']} - #{params['error_Message']}"
    end

    def acknowledge(authcode = nil)
      checksum_ok?
    end

    def checksum_ok?
      checksum_fields = [transaction_status, *user_defined.reverse, customer_email, customer_first_name, product_info, gross, invoice]
      checksum_fields_array = [@salt, *checksum_fields, @key]

      if type == 'EMI' && additional_charges.present?
        checksum_fields_array.unshift(additional_charges)
      end

      unless Digest::SHA512.hexdigest(checksum_fields_array.join("|")) == checksum
        @message = 'Return checksum not matching the data provided'
        return false
      end
      true
    end
  end

  class Return
    def initialize(query_string, options = {})
      @notification = Notification.new(query_string, options)
    end

    def transaction_id
      @notification.transaction_id
    end

    def status( order_id, order_amount )
      if @notification.invoice_ok?( order_id ) && @notification.amount_ok?( BigDecimal.new(order_amount) )
        @notification.status
      else
        'Mismatch'
      end
    end

    def success?
      status( @params['txnid'], @params['amount'] ) == 'Completed'
    end

    def message
      @notification.message
    end
  end
end