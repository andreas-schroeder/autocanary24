require 'aws-sdk-core'

module AutoCanary24
  class CanaryStack
    attr_reader :stack_name

    def initialize(stack_name)
      raise "ERR: stack_name is missing" if stack_name.nil?
      @stack_name = stack_name
    end

    def get_desired_capacity
      asg = get_autoscaling_group
      puts "Get desired capacity for stack"
      asg_client = Aws::AutoScaling::Client.new
      resp = asg_client.describe_auto_scaling_groups({
        auto_scaling_group_names: [asg],
        max_records: 1
      })
      puts "#{resp.data.auto_scaling_groups[0].desired_capacity}"
      resp.data.auto_scaling_groups[0].desired_capacity
    end

    def set_desired_capacity_and_wait(desired_capacity)
      asg = get_autoscaling_group
      puts "Set desire capacity of ASG #{asg} to #{desired_capacity}"
      asg_client = Aws::AutoScaling::Client.new
      resp = asg_client.set_desired_capacity({
        auto_scaling_group_name: asg,
        desired_capacity: desired_capacity,
        honor_cooldown: false,
      })
      puts resp
      # TODO Check if fails

      wait_for_instances_in_asg(asg, desired_capacity)
    end

    def is_attached_to(elb)
      puts "is attached to #{elb}?"
      asg = get_autoscaling_group
      elbs = get_attached_loadbalancers(asg) unless asg.nil?
      (elbs.any? { |e| e.load_balancer_name == elb })
    end

    def detach_from_elb_and_wait(elb)
      puts "detach_load_balancers"
      asg = get_autoscaling_group
      asg_client = Aws::AutoScaling::Client.new
      asg_client.detach_load_balancers({auto_scaling_group_name: asg, load_balancer_names: [elb]})
      # TODO Check for success
      # TODO Wait
    end

    def attach_to_elb_and_wait(elb, number_of_instances)
      puts "attach_load_balancers"
      asg = get_autoscaling_group
      asg_client = Aws::AutoScaling::Client.new
      asg_client.attach_load_balancers({auto_scaling_group_name: asg, load_balancer_names: [elb]})
      # TODO Check for success

      wait_for_instances_on_elb(asg, elb)
    end



    private
    def wait_for_instances_on_elb(asg, elb)
      puts "wait_for_instances_on_elb"

      asg_client = Aws::AutoScaling::Client.new
      instances = asg_client.describe_auto_scaling_groups({auto_scaling_group_names: [asg]})[:auto_scaling_groups][0][:instances].map{ |i| { instance_id: i[:instance_id] } }
      puts "Waiting for the following new instances to get healthy in ELB:"
      instances.map{ |i| puts i[:instance_id] }
      elb_client = Aws::ElasticLoadBalancing::Client.new
      while true
        begin
          elb_instances = elb_client.describe_instance_health({load_balancer_name: elb, instances: instances})
          break if elb_instances[:instance_states].select{ |s| s.state != 'InService' }.length == 0
        rescue Aws::ElasticLoadBalancing::Errors::InvalidInstance
        end
        sleep 5
        # TODO add retry limit and think about what to do then
      end

      puts "All new instances are healthy now"
    end

    def wait_for_instances_in_asg(asg, expected_number_of_instances)
      puts "Check #{asg} to have #{expected_number_of_instances} instances running"
      asg_client = Aws::AutoScaling::Client.new
      while true
        instances = asg_client.describe_auto_scaling_groups({auto_scaling_group_names: [asg]})[:auto_scaling_groups][0].instances
        healthy_instances = instances.select{ |i| i[:health_status] == "Healthy" && i[:lifecycle_state]=="InService"}.length
        puts healthy_instances
        break if healthy_instances == expected_number_of_instances

        sleep 5
        # TODO add retry limit and think about what to do then
      end

      puts "All new instances are healthy now"
    end

    def get_attached_loadbalancers(asg)
      puts "get_attached_loadbalancers"
      asg_client = Aws::AutoScaling::Client.new
      asg_client.describe_load_balancers({ auto_scaling_group_name: asg }).load_balancers
    end

    def get_autoscaling_group
      get_first_resource_id('AWS::AutoScaling::AutoScalingGroup')
    end

    def get_first_resource_id(resource_type)
      client = Aws::CloudFormation::Client.new
      resp = client.list_stack_resources({ stack_name: @stack_name }).data.stack_resource_summaries

      resource_ids = resp.select{|x| x[:resource_type] == resource_type }.map { |e| e.physical_resource_id }
      resource_ids[0]
    end
  end
end
