<?php
foreach ([0.0,1.0,2.5,-1.0] as $x) { echo sin($x)," ",cos($x)," ",tan($x),"\n"; }
echo atan2(1,2)," ",hypot(3,4)," ",deg2rad(180)," ",rad2deg(M_PI)," ",fdiv(1,0),"\n";
echo asin(0.5)," ",acos(0.5)," ",atan(1)," ",sinh(1)," ",cosh(1)," ",tanh(1),"\n";
echo asinh(1)," ",acosh(2)," ",atanh(0.5)," ",expm1(1e-10)," ",log1p(1e-10),"\n";
