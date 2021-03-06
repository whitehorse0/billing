module Billing
  class Bill < ActiveRecord::Base
    acts_as_paranoid if respond_to?(:acts_as_paranoid)
    has_paper_trail class_name: 'Billing::Version' if respond_to?(:has_paper_trail)
    
    attr_accessor :perform_print, :perform_fiscalize

    monetize :charges_sum_cents
    monetize :discounts_sum_cents
    monetize :surcharges_sum_cents
    monetize :payments_sum_cents
    monetize :total_cents
    monetize :balance_cents
    
    belongs_to :billable, polymorphic: true
    has_many :charges, inverse_of: :bill, dependent: :destroy
    has_many :modifiers, inverse_of: :bill, dependent: :destroy
    has_many :payments, inverse_of: :bill, dependent: :restrict_with_error
    belongs_to :origin, inverse_of: :bills
    belongs_to :report, inverse_of: :bills
    
    if defined? Extface
      belongs_to :extface_job, class_name: 'Extface::Job'
      belongs_to :print_job, class_name: 'Extface::Job'
    end
    
    accepts_nested_attributes_for :charges, :modifiers, :payments
    
    delegate :payment_model, to: :origin, prefix: :origin, allow_nil: true
    
    scope :unpaid, -> { where(arel_table[:balance_cents].lt(0)) }
    scope :open, -> { where.not(balance_cents: 0) }
    scope :partially_paid, -> { where.not( payments_sum_cents: 0, balance_cents: 0 ) }
    scope :for_report, -> { where(balance_cents: 0 ,report_id: nil) }
    
    before_validation do
      update_sumaries
      self.origin = payments.first.try(:origin) unless origin.present? or payments.many?
    end
    before_create do
      self.number = "#{billable.id}:#{billable.billing_bills.count}"
      self.name = "B:#{number}" if name.nil?
    end
    before_save :perform_autofin, if: :becomes_paid?
    after_commit :create_fiscal_job, on: [ :create, :update ]
    after_commit :create_print_job, on: [ :create, :update ]
    
    validates_numericality_of :total, greater_than_or_equal_to: 0
    validates_numericality_of :balance, less_than_or_equal_to: 0
    validates_presence_of :origin, if: :has_payments?
    
    validates_absence_of :payments_of_diff_models?, 
      :payments_of_diff_fiscalization?, :multiple_cash_payments?, if: :has_payments?
    
    def charge(*args)
      charges.wild *args
    end
    
    def modify(*args)
      modifiers.wild *args
    end
    
    def pay(*args)
      payments.wild *args
    end
    
    def modifier_items
      calculate_modifiers
    end
    
    def payment_types
      billable.try(:billing_payment_types) || billable.try(:payment_types) #|| Billing::PaymentType.all #FIXME
    end
    
    def origins
      billable.try(:billing_origins) || billable.try(:origins) #|| Billing::Origin.all #FIXME
    end
    
    def tax_groups
      billable.try(:tax_groups)
    end
    
    def has_payments?
      payments.any?
    end
    
    def paid?
      has_payments? && balance.zero?
    end
    
    def build_typed_payment(attributes = {})
      payment_origin = attributes[:origin] || origins.find_by_id(attributes[:origin_id])
      payments.new(attributes.merge(type: (payment_origin || origin).try(:payment_model) || 'Billing::PaymentWithType'))
    end
    
    def fiscalize(detailed = false)
      #TODO create resque job
      #self.extface_job = origin.fiscal_device.driver.fiscalize(self, detailed) if fiscalizable? && origin.try(:fiscal_device)
      #self.extface_job if save
      if defined?(Extface) && fiscalizable? && device = origin.try(:fiscal_device)
        #self.extface_job = origin.fiscal_device.driver.fiscalize(self) if fiscalizable? && origin.try(:fiscal_device)
        self.extface_job = device.jobs.new
        self.perform_fiscalize = true
        self.extface_job if save
      end
    end
    
    def global_modifier_value
      global_modifiers = modifiers.select{ |m| m.charge.nil? }
      if global_modifiers.any?
        gvalue = Money.new(0)
        global_modifiers.each do |global_modifier|
          gvalue += global_modifier.percent_ratio.nil? ? global_modifier.fixed_value : (charges.to_a.sum(0.to_money, &:value).to_money * global_modifier.percent_ratio)
        end
        return gvalue
      end
    end
    
    def find_operator_mapping_for(fiscal_driver)
      # get operator, who close/pay the bill?
      #operator.operator_fiscal_driver_mapping.find_by(extface_driver_id: fiscal_driver.id) if fiscal_driver.fiscal?
    end
    
    def fiscalizable?
      self.finalized_at.present? && payments.select(&:fiscal?).any? && origin.try(:fiscal_device) && balance.zero?
    end
    
    def printable?
      origin.print_device.present?
    end

    private
      def calculate_modifiers
        charges_a = charges.to_a
        @modifier_items = ModifierItems.new.tap() do |items|
          # modifiers.select{ |m| m.charge.present? }.each do |charge_modifier|
          #   charge = charges_a.find{ |c| c == charge_modifier.charge }
          #   mod_value = charge_modifier.percent_ratio.nil? ? charge_modifier.fixed_value : (charge_modifier.charge.price * charge_modifier.percent_ratio)
          #   charge.value = charge.price + mod_value
          #   items << Charge.new(price: mod_value, chargable: charge)
          # end
          charges_a.select{ |c| c.modifier.present? }.each do |charge|
            mod_value = charge.modifier.percent_ratio.nil? ? charge.modifier.fixed_value : (charge.modifier.charge.price * charge.modifier.percent_ratio)
            charge.value = charge.price + mod_value
            items << Charge.new(price: mod_value, chargable: charge)
          end
          modifiers.select{ |m| m.charge.nil? }.each do |global_modifier|
            items << Charge.new(price: global_modifier.percent_ratio.nil? ? global_modifier.fixed_value : (charges_a.sum(&:value).to_money * global_modifier.percent_ratio))
          end
        end
      end
      def update_sumaries
        calculate_modifiers
        self.charges_sum = charges.to_a.sum(0.to_money, &:price).to_money
        self.discounts_sum = @modifier_items.discounts.sum(0.to_money, &:price).to_money
        self.surcharges_sum = @modifier_items.surcharges.sum(0.to_money, &:price).to_money
        self.payments_sum = payments.to_a.sum(0.to_money, &:value).to_money
        self.total = charges.to_a.sum(0.to_money, &:price) + surcharges_sum + discounts_sum
        self.balance = payments_sum - total
      end
      
      def payments_of_diff_models?
        payments.to_a.group_by(&:type).many?
      end
      
      def payments_of_diff_fiscalization?
        payments.to_a.group_by(&:fiscal?).many?
      end
      
      def multiple_cash_payments?
        payments.to_a.select(&:cash?).many?
      end
      
      def becomes_paid?
        finalized_at.nil? && has_payments? && balance.zero?
      end
      
      def perform_autofin
        if autofin
          self.finalized_at = Time.now
          if defined?(Extface) && fiscalizable? && device = origin.try(:fiscal_device)
            #self.extface_job = origin.fiscal_device.driver.fiscalize(self) if fiscalizable? && origin.try(:fiscal_device)
            self.extface_job = device.jobs.new
            self.perform_fiscalize = true
          end
          if defined?(Extface) && printable? && print_device = origin.try(:print_device)
            #self.extface_job = origin.fiscal_device.driver.fiscalize(self) if fiscalizable? && origin.try(:fiscal_device)
            self.print_job = print_device.jobs.new
            self.perform_print = true
          end
        end
        true
      end
      
      def create_fiscal_job
        if @perform_fiscalize && defined?(Resque) && defined?(Extface) && device = origin.try(:fiscal_device)
          Resque.enqueue_to("extface_#{device.id}", Billing::IssueFiscalDoc, self.id)
        end if fiscalizable?
        true
      end

      def create_print_job
        if @perform_print && defined?(Resque) && defined?(Extface) && print_device = origin.try(:print_device)
          Resque.enqueue_to("extface_#{print_device.id}", Billing::IssuePrintDoc, self.id)
        end if printable?
        true
      end
  end
end
