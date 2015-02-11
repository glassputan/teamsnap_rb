require "spec_helper"
require "teamsnap"

RSpec.describe "teamsnap_rb" do
  let!(:client) { TeamSnap::Client.new("") }

  it "registers new classes via introspection of the root collection" do
    expect { TeamSnap::Team }.to_not raise_error
  end

  it "handles fetching data via queries" do
    ts = TeamSnap::Team.search(:id => 1)

    expect(ts).to_not be_empty
    expect(ts[0].id).to eq(1)
  end

  it "handles queries with no data" do
    ts = TeamSnap::Team.search(:id => 0)

    expect(ts).to be_empty
  end

  it "raises an exception when a query is invalid" do
    expect {
      TeamSnap::Team.search(:foo => :bar)
    }.to raise_error(
      ArgumentError,
      "Invalid argument(s). Valid argument(s) are [:id, :team_id, :user_id]"
    )
  end

  it "handles executing an action via commands" do
    ms = TeamSnap::Member.disable_member(:member_id => 1)

    expect(ms).to_not be_empty
    expect(ms[0].id).to eq(1)
  end

  it "raises and exception when a command is invalid" do
    expect {
      TeamSnap::Member.disable_member(:foo => :bar)
    }.to raise_error(
      ArgumentError,
      "Invalid argument(s). Valid argument(s) are [:member_id]"
    )
  end

  it "can handle errors generated by command" do
    expect {
      TeamSnap::Member.disable_member
    }.to raise_error(
      TeamSnap::Error,
      "You must provide the member_id."
    )
  end

  it "adds .find if .search is available" do
    t = TeamSnap::Team.find(1)

    expect(t.id).to eq(1)
  end

  it "raises an exception if .find returns nothing" do
    expect {
      TeamSnap::Team.find(0)
    }.to raise_error(
      TeamSnap::NotFound,
      "Could not find a TeamSnap::Team with an id of '0'."
    )
  end

  it "allows for simple inspection of items" do
    t = TeamSnap::Team.find(1)

    expect(t.inspect).to eq("#<TeamSnap::Team id=1>")
  end

  it "can follow singular links" do
    m = TeamSnap::Member.find(1)
    t = m.team

    expect(t.id).to eq(1)
  end

  it "can handle links with no data" do
    m = TeamSnap::Member.find(1)
    as = m.assignments

    expect(as).to be_empty
  end

  it "can follow plural links" do
    t = TeamSnap::Team.find(1)
    ms = t.members

    expect(ms.size).to eq(10)
  end

  it "can use bulk load" do
    cs = TeamSnap.bulk_load(:team_id => 1, :types => [:team, :member])

    expect(cs).to_not be_empty
    expect(cs.size).to eq(11)
    expect(cs[0]).to be_a(TeamSnap::Team)
    expect(cs[0].id).to eq(1)
    cs[1..10].each_with_index do |c, idx|
      expect(c).to be_a(TeamSnap::Member)
      expect(c.id).to eq(idx+1)
    end
  end

  it "can handle an empty bulk load" do
    cs = TeamSnap.bulk_load(:team_id => 0, :types => [:team, :member])

    expect(cs).to be_empty
  end

  it "can handle an error with bulk load" do
    expect {
      TeamSnap.bulk_load
    }.to raise_error(
      TeamSnap::Error,
      "You must include a team_id parameter"
    )
  end
end
