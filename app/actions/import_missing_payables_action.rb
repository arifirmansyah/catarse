class ImportMissingPayablesAction
  def initialize(payment:)
    @payment = payment
  end

  def call
    fetch_transaction
    fetch_payables

    return if @payables.size == 0

    ActiveRecord::Base.transaction do
      import_payables
      update_payment_fee
    end
  rescue => e
    raise e
    Raven.extra_context(payment_id: @payment.id)
    Raven.capture_exception(e, level: 'fatal')
  end

  def fetch_transaction
    @transaction = retry_block { PagarMe::Transaction.find(@payment.gateway_id) }
  end

  def fetch_payables
    @payables = retry_block { @transaction.payables }
  end

  def import_payables
    @payables.each do |payable|
      import_payable(payable)
    end
  end

  def import_payable(payable)
    gateway_payable = @payment.gateway_payables.find_or_initialize_by(
      gateway_id: payable.id,
      transaction_id: payable.transaction_id
    )
    gateway_payable.fee = payable.fee.to_d / 100.00
    gateway_payable.data = payable.attributes
    gateway_payable.save!
  end

  def update_payment_fee
    @payment.update!(gateway_fee: calculate_fee)
  end

  def calculate_fee
    cost = @transaction.cost.to_f / 100.00
    payables_fee = @payables.to_a.sum(&:fee).to_f / 100.00

    if @payment.is_credit_card?
      cost + payables_fee
    elsif @payment.slip_payment?
      payables_fee == 0 ? cost : payables_fee
    end
  end

  def retry_block
    retries ||= 0
    yield
  rescue Errno::ECONNRESET, PagarMe::ResponseError, SignalException => e
    raise e if retries > 3
    retries += 1
    sleep 3
    retry
  end
end
