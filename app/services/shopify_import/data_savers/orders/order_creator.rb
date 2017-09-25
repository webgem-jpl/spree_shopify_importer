# rubocop:disable Metrics/ClassLength
module ShopifyImport
  module DataSavers
    module Orders
      class OrderCreator < BaseDataSaver
        delegate :user, :attributes, :timestamps, to: :parser

        # rubocop:disable Metrics/MethodLength
        def save!
          Spree::Order.transaction do
            @spree_order = create_spree_order
            assign_spree_order_to_data_feed
            create_spree_line_items
            create_spree_payments
            create_spree_shipments
            create_spree_taxes
            create_spree_promotions
            create_spree_addresses
            # TODO: refunds
          end
          @spree_order.update_columns(timestamps)
        end
        # rubocop:enable Metrics/MethodLength

        private

        # TODO: create user if missing
        def create_spree_order
          order = Spree::Order.new(user: user)
          order.assign_attributes(attributes)
          order.save!
          order
        end

        def create_spree_line_items
          shopify_order.line_items.each do |shopify_line_item|
            ShopifyImport::DataSavers::LineItems::LineItemCreator.new(shopify_line_item,
                                                                      shopify_order,
                                                                      @spree_order).save
          end
        end

        def create_spree_payments
          transactions = shopify_order.transactions.reject { |t| t.kind.eql?('refund') }

          # TODO: to verify
          if children_transactions?(transactions)
            ids = transactions.map(&:id)

            transactions.each do |t|
              check_transaction_is_not_duplicate?(ids, t) && create_spree_payment(t)
            end
          else
            transactions.each { |t| create_spree_payment(t) }
          end
        end

        def check_transaction_is_not_duplicate?(ids, t)
          (!t.kind.eql?('authorization') && ids.include?(t.parent_id))
        end

        def children_transactions?(transactions)
          check_transactions_kinds?(transactions) && check_transactions_parents?(transactions)
        end

        def check_transactions_kinds?(transactions)
          kinds = transactions.map(&:kind)

          kinds.include?('authorization') && kinds.include?('capture')
        end

        def check_transactions_parents?(transactions)
          ids = transactions.map(&:id)
          parent_ids = transactions.map(&:parent_id)

          (parent_ids - ids).compact.empty?
        end

        def create_spree_payment(transaction)
          ShopifyImport::Importers::PaymentImporter.new(transaction, @shopify_data_feed, @spree_order).import!
        end

        def create_spree_shipments
          shopify_order.fulfillments.each do |fulfillment|
            ShopifyImport::Importers::ShipmentImporter.new(fulfillment, @shopify_data_feed, @spree_order).import!
          end
        end

        def create_spree_taxes
          shopify_order.tax_lines.each do |shopify_tax_line|
            spree_tax_rate = create_tax_rate(shopify_tax_line)
            ShopifyImport::DataSavers::Adjustments::TaxCreator.new(shopify_tax_line,
                                                                   @spree_order,
                                                                   spree_tax_rate).create!
          end
        end

        def create_tax_rate(shopify_tax_line)
          ShopifyImport::DataSavers::TaxRates::TaxRateCreator.new(shopify_tax_line, billing_address).create!
        end

        def create_spree_promotions
          shopify_order.discount_codes.each do |shopify_discount_code|
            promotion = create_promotion(shopify_discount_code)
            ShopifyImport::DataSavers::Adjustments::PromotionCreator.new(@spree_order,
                                                                         promotion,
                                                                         shopify_discount_code).create!
          end
        end

        def create_promotion(shopify_discount_code)
          ShopifyImport::DataSavers::Promotions::PromotionCreator.new(@spree_order, shopify_discount_code).create!
        end

        def create_spree_addresses
          create_bill_addreess
          create_ship_address
        end

        def create_bill_addreess
          return if billing_address.blank?

          # HACK: shopify order address does not have id, so i'm not saving data feed.
          address_data_feed = Shopify::DataFeed.new(data_feed: billing_address.to_json)
          @spree_order.bill_address = address_creator.new(address_data_feed, user, true).create!
          @spree_order.save!(validate: false)
        end

        def create_ship_address
          return if ship_address.blank?

          # HACK: shopify order address does not have id, so i'm not saving data feed.
          address_data_feed = Shopify::DataFeed.new(data_feed: ship_address.to_json)
          @spree_order.ship_address = address_creator.new(address_data_feed, user, true).create!
          @spree_order.save!(validate: false)
        end

        def address_creator
          ShopifyImport::DataSavers::Addresses::AddressCreator
        end

        def billing_address
          @billing_address ||= shopify_order.billing_address
        end

        def ship_address
          @shipping_address ||= shopify_order.shipping_address
        end

        def parser
          @parser ||= ShopifyImport::DataParsers::Orders::BaseData.new(shopify_order)
        end

        def shopify_order
          @shopify_order ||= ShopifyAPI::Order.new(data_feed)
        end

        def assign_spree_order_to_data_feed
          @shopify_data_feed.update!(spree_object: @spree_order)
        end
      end
    end
  end
end
