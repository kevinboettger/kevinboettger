#include "testTP.h"
#include "Modules/ModuleManager.h"
#include "Engine/World.h"
#include "Engine/Engine.h"
#include "EngineUtils.h"
#include "Misc/CoreDelegates.h"
#include "ImmerseStressTestActor.h"

class FtestTPModule : public FDefaultGameModuleImpl
{
public:
	virtual void StartupModule() override;
	virtual void ShutdownModule() override;
private:
	FDelegateHandle OnPostLoadMapHandle;
	void OnPostLoadMap(UWorld* World);
};

void FtestTPModule::StartupModule()
{
	OnPostLoadMapHandle = FCoreUObjectDelegates::PostLoadMapWithWorld.AddRaw(this, &FtestTPModule::OnPostLoadMap);
}

void FtestTPModule::ShutdownModule()
{
	FCoreUObjectDelegates::PostLoadMapWithWorld.Remove(OnPostLoadMapHandle);
}

void FtestTPModule::OnPostLoadMap(UWorld* World)
{
	if (!World) return;

	// Skip if there's already one in the level.
	for (TActorIterator<AImmerseStressTestActor> It(World); It; ++It)
	{
		UE_LOG(LogTemp, Display, TEXT("[testTP] ImmerseStressTestActor already in map"));
		return;
	}

	FActorSpawnParameters Params;
	Params.SpawnCollisionHandlingOverride = ESpawnActorCollisionHandlingMethod::AlwaysSpawn;
	AImmerseStressTestActor* Actor = World->SpawnActor<AImmerseStressTestActor>(AImmerseStressTestActor::StaticClass(), FTransform::Identity, Params);
	UE_LOG(LogTemp, Display, TEXT("[testTP] Auto-spawned ImmerseStressTestActor into %s (type=%d)"), *World->GetName(), (int32)World->WorldType);
}

IMPLEMENT_PRIMARY_GAME_MODULE(FtestTPModule, testTP, "testTP");
