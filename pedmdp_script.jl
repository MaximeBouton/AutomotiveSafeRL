rng = MersenneTwister(1)
using AutomotivePOMDPs
using MDPModelChecking
using GridInterpolations, StaticArrays, POMDPs, POMDPToolbox, AutoViz, AutomotiveDrivingModels, Reel
using DeepQLearning, DeepRL
using DiscreteValueIteration
using ProgressMeter, Parameters, JLD

include("util.jl")
include("masking.jl")
include("masked_dqn.jl")
params = UrbanParams(nlanes_main=1,
                     crosswalk_pos =  [VecSE2(6, 0., pi/2), VecSE2(-6, 0., pi/2), VecSE2(0., -5., 0.)],
                     crosswalk_length =  [14.0, 14., 14.0],
                     crosswalk_width = [4.0, 4.0, 3.1],
                     stop_line = 22.0)
env = UrbanEnv(params=params)

mdp = PedMDP(env = env, pos_res=1., vel_res=1., ped_birth=0.7, ped_type=VehicleDef(AgentClass.PEDESTRIAN, 1.0, 3.0))

### MODEL CHECKING

# labels = labeling(mdp)

# @printf("\n")
# @printf("spatial resolution %2.1f m \n", mdp.pos_res)
# @printf("pedestrian velocity resolution %2.1f m/s \n", mdp.vel_ped_res)
# @printf("car velocity resolution %2.1f m/s \n", mdp.vel_res)
# @printf("number of states %d \n", n_states(mdp))
# @printf("number of actions %d \n", n_actions(mdp))
# @printf("\n")

# property = "Pmax=? [ (!\"crash\") U \"goal\"]" 
# threshold = 0.9999
# @printf("Spec: %s \n", property)
# @printf("Threshold: %f \n", threshold)

overwrite = false

# println("Model Checking...")
# result = model_checking(mdp, labels, property, transition_file_name="pedmdp.tra", labels_file_name="pedmdp.lab", overwrite = overwrite)

### MASK

mask = nothing
mask_file = "pedmask.jld"
if isfile(mask_file) && !overwrite
    println("Loading safety mask from pedmask.jld")
    mask_data = JLD.load(mask_file)
    mask = mask_data["mask"]
    @printf("Mask threshold %f \n", mask.threshold)
else
    println("Computing safety mask...")
    mask = SafetyMask(mdp, result, threshold)
    JLD.save(mask_file, "mask", mask)
    println("Mask saved to pedmask.jld")
end


#### Evaluate mask 


rand_pol = MaskedEpsGreedyPolicy(mdp, 1.0, mask, rng)
# @time rewards_mask, steps_mask, violations_mask = evaluation_loop(mdp, rand_pol, n_ep=10000, max_steps=100, rng=rng);
# print_summary(rewards_mask, steps_mask, violations_mask)

### EVALUATE IN HIGH FIDELITY ENVIRONMENT

pomdp = UrbanPOMDP(env=env,
                   ego_goal = LaneTag(2, 1),
                   max_cars=0, 
                   max_peds=1, 
                   car_birth=0.3, 
                   ped_birth=0.7, 
                   obstacles=false, # no fixed obstacles
                   lidar=false,
                   pos_obs_noise = 0., # fully observable
                   vel_obs_noise = 0.);

# println("EVALUATING IN HIGH FIDELITY ENVIRONMENT")

# @time rewards_mask, steps_mask, violations_mask = evaluation_loop(pomdp, rand_pol, n_ep=1000, max_steps=300, rng=rng);
# print_summary(rewards_mask, steps_mask, violations_mask)


#### Training using DQN in high fidelity environment



max_steps = 500000
eps_fraction = 0.5 
eps_end = 0.01 
solver = DeepQLearningSolver(max_steps = max_steps, eps_fraction = eps_fraction, eps_end = eps_end,
                       lr = 0.0001,                    
                       batch_size = 32,
                       target_update_freq = 5000,
                       max_episode_length = 300,
                       train_start = 40000,
                       buffer_size = 400000,
                       eval_freq = 10000,
                       arch = QNetworkArchitecture(conv=[], fc=[32,32,32]),
                       double_q = true,
                       dueling = true,
                       prioritized_replay = true,
                       exploration_policy = masked_linear_epsilon_greedy(max_steps, eps_fraction, eps_end, mask),
                       evaluation_policy = masked_evaluation(mask),
                       verbose = true,
                       logdir = "pedmdp-log/log5",
                       rng = rng)


env = POMDPEnvironment(pomdp)
policy = solve(solver, env)
masked_policy = MaskedDQNPolicy(pomdp, policy, mask)


# evaluate resulting policy
@time rewards_mask, steps_mask, violations_mask = evaluation_loop(pomdp, masked_policy, n_ep=10000, max_steps=100, rng=rng);
print_summary(rewards_mask, steps_mask, violations_mask)

## perf
# Summary for 10000 episodes:
# Average reward: 0.454
# Average # of steps: 17.252
# Average # of violations: 0.000