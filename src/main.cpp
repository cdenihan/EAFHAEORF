#include <iostream>
#include <kipr/wombat.h>
#include <Wombat-CC/Arm.hpp>
#include <Wombat-CC/Drivetrain.hpp>

int main()
{
    std::cout << "Hello, World!" << std::endl;
    Drivetrain Drivetrain(0, 1, 2, 3, 0, 1);

    Drivetrain.SetDebugEnabled(false);

    Drivetrain.SetPerformance(1.0, 1.0, 1.0, 1.0);
    Drivetrain.SetLineTrackingThresholds(200, 200, 3600, 3600);

    return 0;
}