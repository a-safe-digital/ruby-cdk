# frozen_string_literal: true

require "test_helper"

class EnvTest < Minitest::Test
  def test_holds_an_account_and_a_region
    env = RubyCdk::Env.new(account: "111122223333", region: "eu-west-1")

    assert_equal "111122223333", env.account
    assert_equal "eu-west-1", env.region
    assert_equal "111122223333/eu-west-1", env.name
    assert_equal env.name, env.to_s
  end

  def test_rejects_an_account_that_is_not_twelve_digits
    assert_raises(ArgumentError) { RubyCdk::Env.new(account: "1234", region: "eu-west-1") }
    assert_raises(ArgumentError) { RubyCdk::Env.new(account: "11112222333a", region: "eu-west-1") }
  end

  def test_rejects_a_region_that_does_not_look_like_one
    assert_raises(ArgumentError) { RubyCdk::Env.new(account: "111122223333", region: "europe") }
    assert_raises(ArgumentError) { RubyCdk::Env.new(account: "111122223333", region: "EU-WEST-1") }
  end

  def test_accepts_every_shape_of_region_name
    %w[us-east-1 eu-west-1 ap-southeast-2 il-central-1 mx-central-1 us-gov-east-1 cn-northwest-1].each do |region|
      assert_equal region, RubyCdk::Env.new(account: "111122223333", region: region).region
    end
  end

  def test_equal_envs_are_equal_and_usable_as_hash_keys
    a = RubyCdk::Env.new(account: "111122223333", region: "eu-west-1")
    b = RubyCdk::Env.new(account: "111122223333", region: "eu-west-1")

    assert_equal a, b
    assert_equal({ a => 1 }[b], 1)
    assert_predicate a, :frozen?
  end
end
