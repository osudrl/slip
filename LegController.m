classdef LegController < matlab.System & matlab.system.mixin.Propagates
    % Single leg controller for planar biped
    % Controls leg A
    % Rearrange inputs in order to control leg B
    
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    % Block Parameters
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    
    properties
        Ts = 1e-3;
        params = zeros(11, 1);
        kp_ground = zeros(3, 1);
        kd_ground = zeros(3, 1);
        kp_air = zeros(3, 1);
        kd_air = zeros(3, 1);
        leq_neutral = 1;
    end
    
    
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    % Internal State Properties
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    
    properties (Access = private)
        th_target;
        energy_input;
        
        energy_last_cycle;
        energy_accumulator;
        energy_accumulator_count;
        
        touchdown_length;
        takeoff_length;
        post_midstance;
        extension_length;
        
        p_td_attempt;
        td_attempt_leq_target;
        td_attempt_dleq_target;
        
        td_attempt_latched; %kill
        td_leq_target; %kill
        
        X_last;
        err_last;
        kp_last;
    end
    
    
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    % Inherited Methods
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    
    methods (Access = protected)
        
        %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
        % matlab.System Methods
        %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
        
        function setupImpl(~)
        end
        
        
        function [u, target, kp, debug] = stepImpl(obj, control, t, X, signals, energy)
            % control: [energy_target; ratio_target]
            % X: [body_x;    body_xdot;    body_y;  body_ydot;  body_th;  body_thdot;
            %     leg_a_leq; leg_a_leqdot; leg_a_l; leg_a_ldot; leg_a_th; leg_a_thdot;
            %     leg_b_leq; leg_b_leqdot; leg_b_l; leg_b_ldot; leg_b_th; leg_b_thdot]
            % phase: [alpha; beta]
            %   alpha: bias towards leg A or leg B, [-1, 1]
            %   betap: proportion total leg forces, depends on alpha, [0, 1]
            %   beta: unwrapped betap, [0, 4)
            %     0 is flight, A to front
            %     1 is double support, A in front
            %     2 is flight, B to front
            %     3 is double support, B in front
            % feet: [foot_a_contact; foot_b_contact];
            % forces: [leg_a_force; leg_b_force];
            % params: [body_mass; body_inertia; foot_mass; leg_stiffness; leg_damping;
            %          length_motor_inertia; length_motor_damping; angle_motor_inertia;
            %          angle_motor_damping; angle_motor_ratio; gravity]
            
            % Initialization
            if isnan(obj.energy_last_cycle)
                obj.energy_last_cycle = energy;
                obj.X_last = X;
                obj.takeoff_length = X(7);
                obj.touchdown_length = X(7);
            end
            
            % Use average values of gait energy and forward velocity over
            % last cycle for speed/energy regulation
            if any(signals.touchdown)
                obj.energy_last_cycle = obj.energy_accumulator/obj.energy_accumulator_count;
                obj.energy_accumulator_count = 0;
                obj.energy_accumulator = 0;
            end
            obj.energy_accumulator = obj.energy_accumulator + energy;
            obj.energy_accumulator_count = obj.energy_accumulator_count + 1;
            
            % Deal with triggers, etc.
            obj.process_events(signals);
            
            % Angle controller, touchdown properties
            obj.process_touchdown(X, control, signals);
            
            % Energy controller
            energy_target = control(1);
            err = energy_target - obj.energy_last_cycle;
            max_extension = 0.15;
            kp = 1e-3;
            ff = 0.03;
            obj.energy_input = min(max(kp*err + ff, 0), max_extension);
            
            % Get trajectories from subcontrollers and interpolate
            [target, dtarget, kp, kd, p_phase] = obj.subcontroller_interpolation(X, signals.phase);
            
            leq = X(7);
            dleq = X(8);
            th_body = mod(X(5) + pi, 2*pi) - pi;
            dth_body = X(6);
            th_a = X(11);
            dth_a = X(12);
            
            err = target - [leq; th_a; th_body];
            derr = dtarget - [dleq; dth_a; dth_body];
            
            % Compute PD controller output
            u = [1 0 0; 0 1 -1]*(kp.*err + kd.*derr);
            
            % Prevent ground slip
            ground_force = max(obj.params(4)*(X(7) - X(9)), 0);
            friction = 1;
            slip_margin = 2;
            torque_over = max(abs(u(2)) - X(9)*ground_force*friction/slip_margin, 0);
            u(2) = u(2) - signals.feet_fade(1)*torque_over;
            
            obj.X_last = X;
            obj.err_last = err;
            obj.kp_last = kp;
            
%             debug = obj.th_target;
            debug = p_phase;
            if t > 0.848
                0;
            end
        end
        
            
        function resetImpl(obj)
            obj.step_optimizer.reset();
            
            obj.th_target = 0;
            obj.energy_input = 0;
            
            obj.energy_accumulator_count = 0;
            obj.energy_accumulator = 0;
            obj.energy_last_cycle = NaN;
            
            obj.touchdown_length = NaN;
            obj.takeoff_length = NaN;
            obj.post_midstance = false;
            obj.extension_length = 0;
            
            obj.p_td_attempt = 0;
            obj.td_attempt_leq_target = 0;
            obj.td_attempt_dleq_target = 0;
            
            % kill
            obj.td_attempt_latched = false;
            obj.td_leq_target = 0;
            
            obj.X_last = zeros(18, 1);
            obj.err_last = zeros(3, 1);
            obj.kp_last = zeros(3, 1);
        end
        
        
        %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
        % matlab.system.mixin.Propagates methods
        %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
        
        function [flag_1, flag_2, flag_3, flag_4] = isOutputFixedSizeImpl(~)
            flag_1 = true;
            flag_2 = true;
            flag_3 = true;
            flag_4 = true;
        end
        
        
        function [sz_1, sz_2, sz_3, sz_4] = getOutputSizeImpl(~)
            sz_1 = [2 1];
            sz_2 = [3 1];
            sz_3 = [3 1];
            sz_4 = [6 1];
        end
        
        
        function [dt_1, dt_2, dt_3, dt_4] = getOutputDataTypeImpl(~)
            dt_1 = 'double';
            dt_2 = 'double';
            dt_3 = 'double';
            dt_4 = 'double';
        end
        
        
        function [cp_1, cp_2, cp_3, cp_4] = isOutputComplexImpl(~)
            cp_1 = false;
            cp_2 = false;
            cp_3 = false;
            cp_4 = false;
        end
    end
    
    
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    % Private Methods
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    
    methods (Access = private)
        
        %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
        % Subroutines
        %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
        
        function process_events(obj, X, signals)
            % Respond to event signals
            
            if signals.touchdown_fast(1) && signals.feet_fade(1) < 1 && ~obj.post_midstance
                obj.touchdown_length = min(X(7), 1);
            end
            if signals.touchdown(1)
                obj.td_attempt_latched = false;
            end
            if signals.midstance(1)
                obj.post_midstance = true;
            end
            if signals.takeoff_fast(1) && signals.feet_fade(1) > 0 && obj.post_midstance
                obj.takeoff_length = min(X(7), 1);
            end
            if signals.takeoff(1)
                obj.step_optimizer.reset();
                obj.post_midstance = false;
            end
        end
        
        
        function process_touchdown(obj, X, control, signals)
            % Compute properties related to touchdown
            
            % Touchdown angle controller
            if ~obj.td_attempt_latched
                dx0 = X(2);
                target = control(2);
                obj.th_target = 0.08*target + 0.2*(dx0 - target);
                % TODO: calculate desired td angle
                % set th_target so that foot is at this angle with matched
                % ground speed at expected touchdown time
            end
            
            % p_td_attempt determines whether to extend the foot
            % p_td_attempt latches at 1 until reset
            if obj.p_td_attempt < 1
                fade_width = 0.1;
                obj.p_td_attempt = 1 - min(max((obj.th_target - (X(5) + X(11)))/fade_width, 0), 1);
            end
            if signals.feet_fade(1) == 1
                % Reset p_td_attempt when ground contact is estalished
                % TODO: also reset when foot makes a complete sweep without
                % hitting ground
                obj.p_td_attempt = 0;
            end
            
            % Calculate leq targets used to extend the leg
            if obj.p_td_attempt > 0
                fade_width = 0.01; % m
                obj.td_attempt_leq_target = min(max(X(7), obj.td_attempt_leq_target), obj.leq_neutral);
                dfade = min(max((obj.leq_neutral - obj.td_attempt_leq_target)/fade_width, 0), 1);
                td_rate = 1; % m/s
                obj.td_attempt_dleq_target = dfade*td_rate;
            else
                obj.td_attempt_leq_target = 0;
                obj.td_attempt_dleq_target = 0;
            end
        end
        
        
        %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
        % Phase controllers
        %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
        
        function [target, dtarget, kp, kd] = fa_controller(obj, X)
            % Angle to target, increase length until nominal
            % Use d term to extend leg
            
            th_a_target = obj.th_target - X(5);
            obj.td_leq_target = min(max(obj.td_leq_target, X(7)), obj.leq_neutral);
            target = [obj.td_leq_target, th_a_target, 0];
            dtarget = [1, 0, 0];
            
            kp = obj.kp_air;
            kd = obj.kd_air;
        end
        
        
        function [target, dtarget, kp, kd] = da_controller(obj, X)
            % Support leg and stabilize body
            % TODO: push controller on COM velocity
            
            leq_target = obj.touchdown_length;
            target = [leq_target; X(11); 0];
            dtarget = [0; X(12); 0];
            
            kp = obj.kp_ground;
            kd = obj.kd_ground;
        end
        
        
        function [target, dtarget, kp, kd] = sa_controller(obj, X)
            % Support leg and stabilize body, and extend after midstance
            
            extension_time = 0.2;
            if obj.post_midstance
                extension_rate = obj.energy_input/extension_time;
                obj.extension_length = min(obj.extension_length + obj.Ts*extension_rate, obj.energy_input);
                leq_target = obj.touchdown_length + obj.extension_length;
                dleq_target = extension_rate;
            else
                obj.extension_length = 0;
                if isnan(obj.touchdown_length)
                    leq_target = X(7);
                else
                    leq_target = obj.touchdown_length;
                end
                dleq_target = 0;
            end
            
            target = [leq_target; X(11); 0];
            dtarget = [dleq_target; X(12); 0];
            
            kp = obj.kp_ground;
            kd = obj.kd_ground;
        end
        
        
        function [target, dtarget, kp, kd] = fb_controller(obj, X)
            % Mirror and keep out of ground
            
            [leq_target, dleq_target] = obj.get_clearance_length(X);
            th_a_target = -X(17) - 2*X(5);
            dth_a_target = -X(18) - 2*X(6);
            target = [leq_target; th_a_target; 0];
            dtarget = [dleq_target; dth_a_target; 0];
            
            kp = obj.kp_air;
            kd = obj.kd_air;
        end
        
        function [target, dtarget, kp, kd] = db_controller(obj, X)
            % Same as sa controller for now
            
            [target, dtarget, kp, kd] = obj.sa_controller(X);
        end
        
        
        function [target, dtarget, kp, kd] = sb_controller(obj, X)
            % Mirror stance leg until target angle reached, then extend leg
            % until touchdown
            
            movement_dir = sign(X(2));
            p_td = 1 - min(max(movement_dir*(obj.th_target - X(5) - X(11))/0.01, 0), 1);
            
            if p_td <= 0 && ~obj.td_attempt_latched
                obj.td_leq_target = 0;
            end
            
            [leq_target, dleq_target] = obj.get_clearance_length(X);
            th_a_target = -X(17) - 2*X(5);
            dth_a_target = -X(18) - 2*X(6);
            target_m = [leq_target, th_a_target, 0];
            dtarget_m = [dleq_target, dth_a_target, 0];
            
            th_a_target = obj.th_target - X(5);
            obj.td_leq_target = min(max(obj.td_leq_target, X(7)), obj.leq_neutral);
            target_td = [obj.td_leq_target, th_a_target, 0];
            dtarget_td = [1, 0, 0];
            
            target = target_m*(1 - p_td) + target_td*p_td;
            dtarget = dtarget_m*(1 - p_td) + dtarget_td*p_td;
            
            kp = obj.kp_air;
            kd = obj.kd_air;
        end
        
        
        %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
        % Interpolation
        %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
        
        function [target, dtarget, kp, kd, p_phase] = subcontroller_interpolation(obj, X, phase)
            % Phase controllers
            % [flight_a; double_a; stance_a; flight_b; double_b; stance_b]
            target_phase = zeros(3, 6);
            dtarget_phase = zeros(3, 6);
            kp_phase = zeros(3, 6);
            kd_phase = zeros(3, 6);
            [target_phase(:, 1), dtarget_phase(:, 1), kp_phase(:, 1), kd_phase(:, 1)] ...
                = obj.fa_controller(X);
            [target_phase(:, 2), dtarget_phase(:, 2), kp_phase(:, 2), kd_phase(:, 2)] ...
                = obj.da_controller(X);
            [target_phase(:, 3), dtarget_phase(:, 3), kp_phase(:, 3), kd_phase(:, 3)] ...
                = obj.sa_controller(X);
            [target_phase(:, 4), dtarget_phase(:, 4), kp_phase(:, 4), kd_phase(:, 4)] ...
                = obj.fb_controller(X);
            [target_phase(:, 5), dtarget_phase(:, 5), kp_phase(:, 5), kd_phase(:, 5)] ...
                = obj.db_controller(X);
            [target_phase(:, 6), dtarget_phase(:, 6), kp_phase(:, 6), kd_phase(:, 6)] ...
                = obj.sb_controller(X);
            
            % Phase interpolation
            alpha = phase(1);
            beta = phase(2);
            betap = abs(mod(beta + 1, 2) - 1);
            
            p_sa = min(max(alpha, 0), 1);
            p_sb = min(max(-alpha, 0), 1);
            if beta < 2
                p_fb = 0;
                p_db = 0;
                p_fa = (1 - betap)*(1 - abs(alpha));
                p_da = betap*(1 - abs(alpha));
            else
                p_fb = (1 - betap)*(1 - abs(alpha));
                p_db = betap*(1 - abs(alpha));
                p_fa = 0;
                p_da = 0;
            end
            
            p_phase = [p_fa; p_da; p_sa; p_fb; p_db; p_sb];
            kp = kp_phase*p_phase;
            kd = kd_phase*p_phase;
            target = bsxfun(@rdivide, (target_phase.*kp_phase), kp)*p_phase;
            dtarget = bsxfun(@rdivide, (dtarget_phase.*kd_phase), kd)*p_phase;
            
            % If p_phase for nonzero kp_phase values is very small, don't
            % weight the average; prevents NaN and spurious targets
            target_unweighted = target_phase*p_phase;
            dtarget_unweighted = dtarget_phase*p_phase;
            target_invalid = (abs(kp_phase) > 0)*p_phase < 1e-3;
            dtarget_invalid = (abs(kd_phase) > 0)*p_phase < 1e-3;
            target(target_invalid) = target_unweighted(target_invalid);
            dtarget(dtarget_invalid) = dtarget_unweighted(dtarget_invalid);
        end
        
        
        %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
        % Helper Functions
        %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
        
        function [l, dl] = get_clearance_length(obj, X)
            % Get leg length required to clear ground
            
            ground_clearance = 0.1;
            
            y = X(3);
            dy = X(4);
            th = X(5) + X(11);
            dth = X(6) + X(12);
            
            l = (y - ground_clearance)/cos(th);
            dl = dy/cos(th) + dth*sin(th)*(y - ground_clearance)/cos(th)^2;
            
            l_min = 0.5;
            l_max = obj.leq_neutral;
            
            if isnan(l)
                l = obj.leq_neutral;
            end
            
            l = min(max(l, l_min), l_max);
        end

    end
end
