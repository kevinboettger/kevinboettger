// See ImmerseStressTestActor.h for usage.

#include "ImmerseStressTestActor.h"

#include "AkAudioDevice.h"
#include "AkComponent.h"
#include "AkGameplayTypes.h"
#include "Engine/Engine.h"
#include "Engine/GameViewportClient.h"
#include "Engine/World.h"
#include "HAL/IConsoleManager.h"
#include "Misc/CString.h"
#include "Misc/DateTime.h"
#include "Misc/FileHelper.h"
#include "Misc/Paths.h"
#include "Misc/CoreDelegates.h"
#include "HAL/FileManager.h"
#include "HAL/PlatformMisc.h"
#include "TimerManager.h"
#include "AK/SoundEngine/Common/AkSoundEngine.h"

AImmerseStressTestActor* AImmerseStressTestActor::ActiveInstance = nullptr;

AImmerseStressTestActor::AImmerseStressTestActor()
{
	PrimaryActorTick.bCanEverTick = true;
	PrimaryActorTick.bStartWithTickEnabled = true;

	StressEmitter = CreateDefaultSubobject<UAkComponent>(TEXT("StressEmitter"));
	if (StressEmitter)
	{
		RootComponent = StressEmitter;
	}
}

void AImmerseStressTestActor::BeginPlay()
{
	Super::BeginPlay();
	ActiveInstance = this;
	RegisterConsoleCommands();
	UE_LOG(LogTemp, Display, TEXT("[ImmerseStress] Ready. Defaults: event=%s bus=%s shareset=%s"),
		*EventName, *BusName, *ImmerseShareSetName);

	if (bAutoRunOnBeginPlay)
	{
		RunPlan();
	}
}

void AImmerseStressTestActor::EndPlay(const EEndPlayReason::Type EndPlayReason)
{
	if (Phase != EImmerseStressPhase::Idle &&
		Phase != EImmerseStressPhase::Complete &&
		Phase != EImmerseStressPhase::Aborted)
	{
		AbortPlan();
	}
	StopChurn();
	UnregisterConsoleCommands();
	if (ActiveInstance == this)
	{
		ActiveInstance = nullptr;
	}
	Super::EndPlay(EndPlayReason);
}

namespace
{
	static FString FirstArg(const TArray<FString>& Args)
	{
		for (const FString& A : Args) { if (!A.IsEmpty()) return A; }
		return FString();
	}
}

void AImmerseStressTestActor::RegisterConsoleCommands()
{
	IConsoleManager& Mgr = IConsoleManager::Get();

	auto AddCmd = [&](const TCHAR* Name, const TCHAR* Help, FConsoleCommandWithArgsDelegate Del)
	{
		IConsoleCommand* Cmd = Mgr.RegisterConsoleCommand(Name, Help, Del, ECVF_Default);
		if (Cmd) { RegisteredCommands.Add(Cmd); }
	};

	AddCmd(TEXT("immerse.bypass"), TEXT("Bypass the Immerse Audio Renderer mixer on the configured bus."),
		FConsoleCommandWithArgsDelegate::CreateLambda([](const TArray<FString>&)
		{ if (ActiveInstance) ActiveInstance->BypassImmerse(); }));

	AddCmd(TEXT("immerse.enable"), TEXT("Re-enable the Immerse Audio Renderer mixer share-set."),
		FConsoleCommandWithArgsDelegate::CreateLambda([](const TArray<FString>&)
		{ if (ActiveInstance) ActiveInstance->EnableImmerse(); }));

	AddCmd(TEXT("immerse.toggle"), TEXT("Toggle Immerse mixer."),
		FConsoleCommandWithArgsDelegate::CreateLambda([](const TArray<FString>&)
		{ if (ActiveInstance) ActiveInstance->ToggleImmerse(); }));

	AddCmd(TEXT("immerse.stress.start"), TEXT("Start the manual churn loop."),
		FConsoleCommandWithArgsDelegate::CreateLambda([](const TArray<FString>&)
		{ if (ActiveInstance) ActiveInstance->StartChurn(); }));

	AddCmd(TEXT("immerse.stress.stop"), TEXT("Stop the manual churn loop."),
		FConsoleCommandWithArgsDelegate::CreateLambda([](const TArray<FString>&)
		{ if (ActiveInstance) ActiveInstance->StopChurn(); }));

	AddCmd(TEXT("immerse.stress.runplan"), TEXT("Start the automated A/B test plan."),
		FConsoleCommandWithArgsDelegate::CreateLambda([](const TArray<FString>&)
		{ if (ActiveInstance) ActiveInstance->RunPlan(); }));

	AddCmd(TEXT("immerse.stress.abort"), TEXT("Abort the automated test plan."),
		FConsoleCommandWithArgsDelegate::CreateLambda([](const TArray<FString>&)
		{ if (ActiveInstance) ActiveInstance->AbortPlan(); }));

	AddCmd(TEXT("immerse.stress.status"), TEXT("Print harness state."),
		FConsoleCommandWithArgsDelegate::CreateLambda([](const TArray<FString>&)
		{ if (ActiveInstance) ActiveInstance->PrintStatus(); }));
}

void AImmerseStressTestActor::UnregisterConsoleCommands()
{
	IConsoleManager& Mgr = IConsoleManager::Get();
	for (IConsoleCommand* Cmd : RegisteredCommands)
	{
		if (Cmd) { Mgr.UnregisterConsoleObject(Cmd); }
	}
	RegisteredCommands.Reset();
}

void AImmerseStressTestActor::StartChurn()
{
	if (bChurnActive) return;
	bChurnActive = true;
	Accumulator = 0.0;
	UE_LOG(LogTemp, Display, TEXT("[ImmerseStress] Churn START event=%s rate=%.1fHz life=%dms cap=%d immerse=%s"),
		*EventName, PostsPerSecond, EventLifetimeMs, MaxConcurrent,
		bImmerseBypassed ? TEXT("BYPASSED") : TEXT("enabled"));
}

void AImmerseStressTestActor::StopChurn()
{
	if (!bChurnActive && InFlight.Num() == 0) return;
	bChurnActive = false;
	StopAllTracked();
	UE_LOG(LogTemp, Display, TEXT("[ImmerseStress] Churn STOP posted=%lld stopped=%lld dropped=%lld"),
		TotalPosted, TotalStopped, TotalDroppedOverCap);
}

void AImmerseStressTestActor::BypassImmerse()
{
	const FTCHARToUTF8 BusUtf8(*BusName);
	const AKRESULT Res = AK::SoundEngine::SetMixer(BusUtf8.Get(), AK_INVALID_UNIQUE_ID);
	bImmerseBypassed = (Res == AK_Success);
	UE_LOG(LogTemp, Display, TEXT("[ImmerseStress] BypassImmerse(bus=%s) -> %s"),
		*BusName, bImmerseBypassed ? TEXT("OK") : TEXT("FAILED"));
}

void AImmerseStressTestActor::EnableImmerse()
{
	const FTCHARToUTF8 ShareSetUtf8(*ImmerseShareSetName);
	const AkUInt32 ShareSetID = AK::SoundEngine::GetIDFromString(ShareSetUtf8.Get());
	const FTCHARToUTF8 BusUtf8(*BusName);
	const AKRESULT Res = AK::SoundEngine::SetMixer(BusUtf8.Get(), ShareSetID);
	bImmerseBypassed = !(Res == AK_Success);
	UE_LOG(LogTemp, Display, TEXT("[ImmerseStress] EnableImmerse(bus=%s, shareset=%s id=%u) -> %s"),
		*BusName, *ImmerseShareSetName, ShareSetID,
		(Res == AK_Success) ? TEXT("OK") : TEXT("FAILED"));
}

void AImmerseStressTestActor::ToggleImmerse()
{
	if (bImmerseBypassed) { EnableImmerse(); }
	else                  { BypassImmerse(); }
}

void AImmerseStressTestActor::PrintStatus() const
{
	UE_LOG(LogTemp, Display, TEXT("[ImmerseStress] phase=%d immerse=%s churn=%s posted=%lld stopped=%lld dropped=%lld"),
		(int32)Phase,
		bImmerseBypassed ? TEXT("BYPASSED") : TEXT("enabled"),
		bChurnActive ? TEXT("ON") : TEXT("off"),
		TotalPosted, TotalStopped, TotalDroppedOverCap);
}

void AImmerseStressTestActor::Tick(float DeltaSeconds)
{
	Super::Tick(DeltaSeconds);

	const double NowSeconds = GetWorld() ? GetWorld()->GetTimeSeconds() : 0.0;

	for (int32 i = InFlight.Num() - 1; i >= 0; --i)
	{
		if (NowSeconds >= InFlight[i].StopAtSeconds)
		{
			StopPlayingID(InFlight[i].PlayingID);
			InFlight.RemoveAtSwap(i);
		}
	}

	TickPlan(DeltaSeconds);

	if (!bChurnActive) return;

	const double Interval = 1.0 / FMath::Max(0.0001f, PostsPerSecond);
	Accumulator += DeltaSeconds;
	while (Accumulator >= Interval)
	{
		Accumulator -= Interval;

		if (InFlight.Num() >= MaxConcurrent)
		{
			++TotalDroppedOverCap;
			continue;
		}

		const uint32 PID = PostOne();
		if (PID != 0)
		{
			FInFlight Entry;
			Entry.PlayingID = PID;
			Entry.StopAtSeconds = NowSeconds + (EventLifetimeMs / 1000.0);
			InFlight.Add(Entry);
			++TotalPosted;
		}
	}
}

void AImmerseStressTestActor::RunPlan()
{
	if (Phase == EImmerseStressPhase::Warmup ||
		Phase == EImmerseStressPhase::Running ||
		Phase == EImmerseStressPhase::Cooldown)
	{
		UE_LOG(LogTemp, Warning, TEXT("[ImmerseStress] RunPlan ignored -- plan already running."));
		return;
	}

	if (ConcurrencyLevels.Num() == 0)
	{
		UE_LOG(LogTemp, Warning, TEXT("[ImmerseStress] RunPlan: ConcurrencyLevels is empty."));
		return;
	}

	StopChurn();
	PhaseRecords.Reset();
	PlanStepIndex = 0;
	PostsPerSecond = PlanRateHz;
	EventLifetimeMs = PlanEventLifetimeMs;

	if (bWriteCSV)
	{
		const FString Stamp = FDateTime::Now().ToString(TEXT("%Y%m%d_%H%M%S"));
		CSVFilePath = FPaths::ProjectSavedDir() / TEXT("ImmerseStress") / FString::Printf(TEXT("run_%s.csv"), *Stamp);
		EnsureCSVHeader();
	}

	if (bIssueStatCommands)
	{
		IssueViewportConsoleCommand(TEXT("stat unit"));
		IssueViewportConsoleCommand(TEXT("stat audio"));
	}

	UE_LOG(LogTemp, Display,
		TEXT("[ImmerseStress] PLAN START steps=%d rate=%.1fHz life=%dms warmup=%.1fs phase=%.1fs cooldown=%.1fs CSV=%s"),
		PlanStepCount(),
		PlanRateHz, PlanEventLifetimeMs,
		WarmupSeconds, PhaseDurationSeconds, CooldownSeconds,
		bWriteCSV ? *CSVFilePath : TEXT("(disabled)"));

	EnterPhase(EImmerseStressPhase::Warmup);
}

void AImmerseStressTestActor::AbortPlan()
{
	if (Phase == EImmerseStressPhase::Idle ||
		Phase == EImmerseStressPhase::Complete ||
		Phase == EImmerseStressPhase::Aborted)
	{
		return;
	}
	UE_LOG(LogTemp, Warning, TEXT("[ImmerseStress] PLAN ABORT at step %d"), PlanStepIndex);
	StopChurn();
	FinishPlan(true);
}

void AImmerseStressTestActor::EnterPhase(EImmerseStressPhase NewPhase)
{
	Phase = NewPhase;
	PhaseStartSeconds = GetWorld() ? GetWorld()->GetTimeSeconds() : 0.0;

	const int32 LevelIdx = PlanStepIndex / 2;
	const bool  bImmerseOnThisStep = (PlanStepIndex % 2) == 1;
	if (ConcurrencyLevels.IsValidIndex(LevelIdx))
	{
		PhaseConcurrency = FMath::Max(1, ConcurrencyLevels[LevelIdx]);
	}
	bPhaseImmerseEnabled = bImmerseOnThisStep;

	switch (NewPhase)
	{
	case EImmerseStressPhase::Warmup:
	{
		if (bImmerseOnThisStep) { EnableImmerse(); } else { BypassImmerse(); }
		MaxConcurrent = PhaseConcurrency;
		PostsPerSecond = PlanRateHz;
		EventLifetimeMs = PlanEventLifetimeMs;
		LogPhaseMarker(TEXT("WARMUP"));
		StartChurn();
		break;
	}
	case EImmerseStressPhase::Running:
	{
		PhasePostedAtStart = TotalPosted;
		PhaseStoppedAtStart = TotalStopped;
		PhaseDroppedAtStart = TotalDroppedOverCap;
		PhaseFrameMsSamples.Reset();
		PhaseFrameMsSamples.Reserve(FMath::CeilToInt(PhaseDurationSeconds * 120.f));
		LogPhaseMarker(TEXT("RUNNING"));
		break;
	}
	case EImmerseStressPhase::Cooldown:
	{
		LogPhaseMarker(TEXT("COOLDOWN"));
		StopChurn();
		break;
	}
	case EImmerseStressPhase::Complete:
	case EImmerseStressPhase::Aborted:
	case EImmerseStressPhase::Idle:
	default:
		break;
	}
}

void AImmerseStressTestActor::TickPlan(float DeltaSeconds)
{
	if (Phase == EImmerseStressPhase::Idle ||
		Phase == EImmerseStressPhase::Complete ||
		Phase == EImmerseStressPhase::Aborted)
	{
		return;
	}

	const double NowSeconds = GetWorld() ? GetWorld()->GetTimeSeconds() : 0.0;
	const double Elapsed = NowSeconds - PhaseStartSeconds;

	if (Phase == EImmerseStressPhase::Running)
	{
		PhaseFrameMsSamples.Add(DeltaSeconds * 1000.f);
	}

	switch (Phase)
	{
	case EImmerseStressPhase::Warmup:
		if (Elapsed >= WarmupSeconds) { EnterPhase(EImmerseStressPhase::Running); }
		break;
	case EImmerseStressPhase::Running:
		if (Elapsed >= PhaseDurationSeconds) { RecordPhaseAndAdvance(); }
		break;
	case EImmerseStressPhase::Cooldown:
		if (Elapsed >= CooldownSeconds)
		{
			++PlanStepIndex;
			if (PlanStepIndex >= PlanStepCount())
			{
				FinishPlan(false);
			}
			else
			{
				EnterPhase(EImmerseStressPhase::Warmup);
			}
		}
		break;
	default:
		break;
	}
}

void AImmerseStressTestActor::RecordPhaseAndAdvance()
{
	FImmerseStressPhaseRecord R;
	R.PhaseIndex = PlanStepIndex;
	R.bImmerseEnabled = bPhaseImmerseEnabled;
	R.Concurrency = PhaseConcurrency;
	R.RateHz = PlanRateHz;
	R.LifetimeMs = PlanEventLifetimeMs;
	R.DurationSeconds = PhaseDurationSeconds;
	R.Posted = TotalPosted - PhasePostedAtStart;
	R.Stopped = TotalStopped - PhaseStoppedAtStart;
	R.Dropped = TotalDroppedOverCap - PhaseDroppedAtStart;
	R.FrameSamples = PhaseFrameMsSamples.Num();
	ComputeFrameStats(PhaseFrameMsSamples, R.AvgFrameMs, R.P50FrameMs, R.P95FrameMs, R.MaxFrameMs);

	PhaseRecords.Add(R);

	UE_LOG(LogTemp, Display,
		TEXT("[ImmerseStress] PHASE %d done immerse=%s conc=%d posted=%lld stopped=%lld dropped=%lld frames=%d avg=%.2fms"),
		R.PhaseIndex, R.bImmerseEnabled ? TEXT("ON") : TEXT("off"),
		R.Concurrency, R.Posted, R.Stopped, R.Dropped,
		R.FrameSamples, R.AvgFrameMs);

	if (bWriteCSV) { AppendCSVRow(R); }

	EnterPhase(EImmerseStressPhase::Cooldown);
}

void AImmerseStressTestActor::FinishPlan(bool bAborted)
{
	StopChurn();
	Phase = bAborted ? EImmerseStressPhase::Aborted : EImmerseStressPhase::Complete;

	UE_LOG(LogTemp, Display, TEXT("[ImmerseStress] PLAN %s -- %d phases recorded."),
		bAborted ? TEXT("ABORTED") : TEXT("COMPLETE"), PhaseRecords.Num());

	if (bQuitOnPlanComplete)
	{
		if (UWorld* W = GetWorld())
		{
			FTimerHandle Th;
			W->GetTimerManager().SetTimer(Th, FTimerDelegate::CreateLambda([]()
			{
				FPlatformMisc::RequestExit(false);
			}), FMath::Max(0.f, QuitGraceSeconds), false);
		}
		else
		{
			FPlatformMisc::RequestExit(false);
		}
	}
}

void AImmerseStressTestActor::EnsureCSVHeader()
{
	const FString DirPath = FPaths::GetPath(CSVFilePath);
	IFileManager::Get().MakeDirectory(*DirPath, true);

	const FString Header = TEXT(
		"phase_idx,immerse,concurrency,rate_hz,life_ms,duration_s,"
		"posted,stopped,dropped,frames,avg_frame_ms,p50_frame_ms,p95_frame_ms,max_frame_ms\n");
	FFileHelper::SaveStringToFile(Header, *CSVFilePath,
		FFileHelper::EEncodingOptions::ForceUTF8WithoutBOM,
		&IFileManager::Get(),
		FILEWRITE_None);
}

void AImmerseStressTestActor::AppendCSVRow(const FImmerseStressPhaseRecord& R)
{
	const FString Row = FString::Printf(
		TEXT("%d,%s,%d,%.2f,%d,%.2f,%lld,%lld,%lld,%d,%.3f,%.3f,%.3f,%.3f\n"),
		R.PhaseIndex,
		R.bImmerseEnabled ? TEXT("on") : TEXT("off"),
		R.Concurrency,
		R.RateHz,
		R.LifetimeMs,
		R.DurationSeconds,
		R.Posted, R.Stopped, R.Dropped,
		R.FrameSamples,
		R.AvgFrameMs, R.P50FrameMs, R.P95FrameMs, R.MaxFrameMs);

	FFileHelper::SaveStringToFile(Row, *CSVFilePath,
		FFileHelper::EEncodingOptions::ForceUTF8WithoutBOM,
		&IFileManager::Get(),
		FILEWRITE_Append);
}

void AImmerseStressTestActor::ComputeFrameStats(TArray<float>& Samples,
	float& OutAvg, float& OutP50, float& OutP95, float& OutMax)
{
	OutAvg = OutP50 = OutP95 = OutMax = 0.f;
	if (Samples.Num() == 0) return;

	double Sum = 0.0;
	float Mx = 0.f;
	for (float S : Samples) { Sum += S; if (S > Mx) Mx = S; }
	OutAvg = static_cast<float>(Sum / Samples.Num());
	OutMax = Mx;

	Samples.Sort();
	const int32 N = Samples.Num();
	const int32 P50Idx = FMath::Clamp(FMath::FloorToInt(N * 0.50f), 0, N - 1);
	const int32 P95Idx = FMath::Clamp(FMath::FloorToInt(N * 0.95f), 0, N - 1);
	OutP50 = Samples[P50Idx];
	OutP95 = Samples[P95Idx];
}

void AImmerseStressTestActor::IssueViewportConsoleCommand(const TCHAR* Cmd)
{
	if (UWorld* W = GetWorld())
	{
		if (UGameViewportClient* VP = W->GetGameViewport())
		{
			VP->ConsoleCommand(Cmd);
		}
	}
}

void AImmerseStressTestActor::LogPhaseMarker(const TCHAR* Tag) const
{
	UE_LOG(LogTemp, Display, TEXT("[ImmerseStress] >>> %s step=%d immerse=%s conc=%d"),
		Tag, PlanStepIndex,
		bPhaseImmerseEnabled ? TEXT("ON") : TEXT("off"),
		PhaseConcurrency);
}

uint32 AImmerseStressTestActor::PostOne()
{
	FAkAudioDevice* Dev = FAkAudioDevice::Get();
	if (!Dev || !StressEmitter) return 0;

	const AkPlayingID PID = Dev->PostEvent(EventName, StressEmitter);
	return (PID == AK_INVALID_PLAYING_ID) ? 0u : static_cast<uint32>(PID);
}

void AImmerseStressTestActor::StopPlayingID(uint32 PlayingID)
{
	FAkAudioDevice* Dev = FAkAudioDevice::Get();
	if (!Dev || PlayingID == 0) return;

	Dev->ExecuteActionOnPlayingID(
		AkActionOnEventType::Stop,
		static_cast<AkPlayingID>(PlayingID),
		0,
		EAkCurveInterpolation::Linear);
	++TotalStopped;
}

void AImmerseStressTestActor::StopAllTracked()
{
	for (const FInFlight& E : InFlight)
	{
		StopPlayingID(E.PlayingID);
	}
	InFlight.Reset();
}
