#include <iostream>
#include <thread>
#include <kipr/wombat.h>
#include <Wombat-CC/Arm.hpp>
#include <Wombat-CC/Drivetrain.hpp>

namespace ShoulderPositions
{
    constexpr int DOWN = 1900;
    constexpr int UP = 830;
} // namespace ShoulderPositions

namespace ElbowPositions
{
    constexpr int DOWN = 0;
    constexpr int UP = 0;
} // namespace ElbowPositions

namespace ClawPositions
{
    constexpr int CLOSED = 2000;
    constexpr int OPEN = 850;
} // namespace ClawPositions

// Arm position struct
constexpr Arm::ArmPosition HomePosition = {
    ShoulderPositions::DOWN, ElbowPositions::DOWN, ClawPositions::OPEN};

constexpr Arm::ArmPosition DownPositionOpen = {
    ShoulderPositions::DOWN, ElbowPositions::DOWN, ClawPositions::OPEN};

constexpr Arm::ArmPosition DownPositionClosed = {
    ShoulderPositions::DOWN, ElbowPositions::DOWN, ClawPositions::CLOSED};

constexpr Arm::ArmPosition UpPositionOpen = {
    ShoulderPositions::UP, ElbowPositions::UP, ClawPositions::OPEN};

constexpr Arm::ArmPosition UpPositionClosed = {
    ShoulderPositions::UP, ElbowPositions::UP, ClawPositions::CLOSED};

// Tick Numbers
constexpr int TICKS_PER_180 = 3950;
constexpr int TICKS_PER_90 = TICKS_PER_180 / 2;
constexpr int TICKS_PER_45 = TICKS_PER_180 / 4;
constexpr int TICKS_PER_DEGREE = TICKS_PER_180 / 180;

namespace MotorPorts
{
    constexpr int ARM_SHOULDER = 0;
    constexpr int ARM_ELBOW = 1;

    constexpr int DRIVETRAIN_FL = 0;
    constexpr int DRIVETRAIN_FR = 1;
    constexpr int DRIVETRAIN_RL = 2;
    constexpr int DRIVETRAIN_RR = 3;
} // namespace MotorPorts

namespace LineSensorPorts
{
    constexpr int FRONT_LEFT = 0;
    constexpr int FRONT_RIGHT = 1;
    constexpr int REAR_RIGHT = 2;
    constexpr int REAR_LEFT = 3;
} // namespace LineSensorPorts

namespace LineCalibration
{
    constexpr int WHITE_FL = 200;
    constexpr int WHITE_FR = 200;
    constexpr int WHITE_RR = 200;
    constexpr int WHITE_RL = 200;

    constexpr int BLACK_FL = 3600;
    constexpr int BLACK_FR = 3600;
    constexpr int BLACK_RR = 3600;
    constexpr int BLACK_RL = 3600;
} // namespace LineCalibration

namespace Runtime
{
    constexpr int SHUTDOWN_SECONDS = 118;
} // namespace Runtime

void kill()
{
    std::thread([]()
                {
        while (true)
        {
            if (push_button() == 1)
            {
                std::cout << "Kill button pressed. Stopping motors and servos." << std::endl;

                ao();
                disable_servos();

                // Hard stop the program
                std::exit(0);
            }

            msleep(10);
        } })
        .detach();
}

int main()
{
    kill();

    std::cout << "Welcome to your Wombat CC project (C++)" << std::endl;
    std::cout << "Using KIPR libwallaby v" << KIPR_VERSION << std::endl;

    Arm Arm(MotorPorts::ARM_SHOULDER, MotorPorts::ARM_ELBOW);
    Drivetrain Drivetrain(MotorPorts::DRIVETRAIN_FL,
                          MotorPorts::DRIVETRAIN_FR,
                          MotorPorts::DRIVETRAIN_RL,
                          MotorPorts::DRIVETRAIN_RR);

    Arm.SetDebugEnabled(false);
    Drivetrain.SetDebugEnabled(false);

    Drivetrain.SetPerformance(1.0, 1.0, 1.0, 1.0);
    Drivetrain.ConfigureLineTrackingSensors(LineSensorPorts::FRONT_LEFT,
                                            LineSensorPorts::FRONT_RIGHT,
                                            LineSensorPorts::REAR_RIGHT,
                                            LineSensorPorts::REAR_LEFT);
    Drivetrain.SetLineTrackingThresholds(LineCalibration::WHITE_FL,
                                         LineCalibration::WHITE_FR,
                                         LineCalibration::WHITE_RR,
                                         LineCalibration::WHITE_RL,
                                         LineCalibration::BLACK_FL,
                                         LineCalibration::BLACK_FR,
                                         LineCalibration::BLACK_RR,
                                         LineCalibration::BLACK_RL);

    shut_down_in(Runtime::SHUTDOWN_SECONDS);

    Arm.SetPosition(DownPositionOpen);

    // Drivetrain.DriveLineTracking.Forward(2500, 500);
    // Drivetrain.DriveLineTracking.Backward(2500, 500);

    // msleep(1000);

    Drivetrain.StrafeLineTracking.LeftToLine(500);

    Arm.SetPosition(UpPositionOpen);
    return 0;
}