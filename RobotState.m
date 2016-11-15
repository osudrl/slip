function X0 = RobotState()

X0.body.x      = 0;
X0.body.y      = 1;
X0.body.theta  = 0;
X0.body.dx     = 0;
X0.body.dy     = 0;
X0.body.dtheta = 0;

X0.right.l         = 1;
X0.right.l_eq      = 1;
X0.right.theta     = 0;
X0.right.theta_eq  = 0;
X0.right.dl        = 0;
X0.right.dl_eq     = 0;
X0.right.dtheta    = 0;
X0.right.dtheta_eq = 0;

X0.left.l         = 1;
X0.left.l_eq      = 1;
X0.left.theta     = 0;
X0.left.theta_eq  = 0;
X0.left.dl        = 0;
X0.left.dl_eq     = 0;
X0.left.dtheta    = 0;
X0.left.dtheta_eq = 0;
